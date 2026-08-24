// The "All" overview tab — port of the macOS AllUsageOverview cards
// (remake polish d2852ed4 / 4852ab68 / 986f49a8):
// total-cost hero + period picker + stacked bars + token-share bar,
// click-to-pin day detail (compact model rows), 120-day heatmap, top models.

import {
  Combined, CombinedDay, HourlyUsage, UsageReport, UsageSourceId, BudgetStatus,
  usd, usdWhole, tokens, tokensAndUsd, dayLabel, scanConfidence, monthlyForecast,
} from "./usage";
import { t, currentLang } from "./i18n";
import { logoMark } from "./logos";
import { showDayPanel, showActivityPanel, bindHoverPanel, closeDayPanelOnly } from "./side-panel";

const PERIOD_KEY = "birdnion.allChartDays";

/** Cửa sổ ngày đang chọn ở chart — các khối khác của tab All bám theo. */
export function allChartDays(): number {
  return Number(localStorage.getItem(PERIOD_KEY)) || 30;
}
/** Chart + top-models period chips (heatmap fills width independently). */
const PERIODS = [1, 7, 30, 90, 120]; // 1 = the 24h hourly view
const PERIOD_CHANGE_EVENT = "birdnion-all-period";
/** Cap model rows in day-detail so the breakdown stays shorter than the chart. */
const MAX_DETAIL_MODELS = 6;

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}


// --- Budget & monthly forecast (Phase 2) ------------------------------------

/** Reuses the `provider-tab.ts` quota tone convention (ok/warning/critical)
 * keyed off budget risk instead of remaining quota. Kept local — the
 * All-tab budget card and per-provider quota windows are different enough
 * risk models that sharing one function would couple unrelated concerns. */
function budgetTone(status: BudgetStatus): string {
  if (status === "already-over") return "critical";
  if (status === "forecast-over") return "warning";
  return "ok";
}

/** Weekly budget + linear-projection forecast card. Only rendered when a
 * budget is configured (`monthlyForecast` returns non-null) — `main.ts`
 * places it last in the All tab, after the configured-agents row. Estimated
 * from local logs of all six cost sources, current calendar week — read-only
 * summary. */
export function budgetForecastCard(combined: Combined, budgetUsd: number | null): HTMLElement | null {
  const forecast = monthlyForecast(combined.daily, budgetUsd);
  if (!forecast) return null;
  return renderFullBudgetCard(forecast);
}

function renderFullBudgetCard(forecast: NonNullable<ReturnType<typeof monthlyForecast>>): HTMLElement {
  const tone = budgetTone(forecast.status);
  const statusLabel = t(`budgetStatus.${forecast.status}`);
  const card = el("section", "card budget-card");

  // Design: title + status; big "$WTD / $budget" + "dự phóng $X"; bar;
  // "CÒN LẠI $Y · N NGÀY NỮA HẾT TUẦN".
  const head = el("div", "budget-head");
  head.append(el("span", "summary-label", t("budgetMonthly")));
  head.append(el("span", `budget-status ${tone}`, statusLabel));
  card.append(head);

  const amounts = el("div", "budget-amounts");
  const mtd = el("div", "budget-mtd-hero");
  mtd.append(el("span", "budget-mtd-main", usd(forecast.monthToDateUsd)));
  mtd.append(el("span", "budget-mtd-cap", ` / ${usd(forecast.budgetUsd)}`));
  amounts.append(mtd);
  amounts.append(el("div", `budget-projected ${tone}`,
    t("budgetProjectedAmount", { amount: usd(forecast.projectedUsd) })));
  card.append(amounts);

  const track = el("div", "window-track budget-track");
  const fill = el("div", `window-fill ${tone}`);
  fill.style.width = `${Math.max(0, Math.min(100, forecast.usedPct))}%`;
  track.append(fill);
  card.append(track);

  const daysLeft = Math.max(0, forecast.daysInMonth - forecast.daysElapsed);
  const remainLabel = forecast.remainingUsd >= 0
    ? t("budgetRemainingWithDays", {
      amount: usd(forecast.remainingUsd),
      n: daysLeft,
    })
    : t("budgetOverBy", { amount: usd(-forecast.remainingUsd) });
  card.append(el("div", `budget-remaining ${tone}`, remainLabel));

  const hint = t("budgetHint", {
    mtd: usd(forecast.monthToDateUsd),
    projected: usd(forecast.projectedUsd),
    budget: usd(forecast.budgetUsd),
    status: statusLabel,
  });
  card.title = hint;
  card.setAttribute("aria-label", hint);
  return card;
}

/** One provider's own weekly budget vs. spend — same full card layout as
 * the All-tab `budgetForecastCard` (title + status, hero amounts, bar,
 * remaining · days left). Returns `null` when no budget is configured.
 *
 * Trust: `"unavailable"` confidence never claims "on track" from zero —
 * renders a no-data row instead. */
export function providerBudgetCard(
  id: UsageSourceId,
  label: string,
  report: UsageReport | null,
  combined: Combined,
  budgetUsd: number | null,
): HTMLElement | null {
  if (budgetUsd == null || !Number.isFinite(budgetUsd) || budgetUsd <= 0) return null;

  const state = scanConfidence(report);
  if (state === "unavailable") {
    const card = el("section", "card budget-card");
    card.append(el("div", "summary-label", t("budgetMonthly")));
    const row = el("div", "budget-provider-row");
    const left = el("span", "legend-item");
    left.append(logoMark(id, "agents-row-logo"));
    left.append(el("span", "budget-provider-name", label));
    row.append(left);
    row.append(el("span", "budget-provider-nodata", t("budgetPerProviderNoData")));
    const hint = t("budgetPerProviderNoDataHint", { source: label });
    row.title = hint;
    row.setAttribute("aria-label", hint);
    card.append(row);
    return card;
  }

  const forecast = monthlyForecast(combined.daily, budgetUsd, new Date(), id);
  if (!forecast) return null;
  return renderFullBudgetCard(forecast);
}

// --- Chart card -----------------------------------------------------------

export function chartCard(
  combined: Combined,
  claudeHourly: HourlyUsage[],
  includedSourceCount = 0,
): HTMLElement {
  const card = el("section", "card");
  let period = Number(localStorage.getItem(PERIOD_KEY)) || 30;
  if (!PERIODS.includes(period)) period = 30;
  // Click-to-pin day detail only (default hidden). Hover never opens detail.
  let pinnedDay: CombinedDay | null = null;

  const render = () => {
    card.textContent = "";
    const windowDaily = combined.daily.slice(-period);
    const wUsd = windowDaily.reduce((s, d) => s + d.usd, 0);
    const wTokens = windowDaily.reduce((s, d) => s + d.tokens, 0);
    const is24h = period === 1;
    const claude24Usd = claudeHourly.reduce((s, h) => s + h.usd, 0);
    const claude24Tokens = claudeHourly.reduce((s, h) => s + h.tokens, 0);
    const today = combined.daily[combined.daily.length - 1];

    const periodUsd = is24h
      ? claude24Usd + (today?.codexUsd ?? 0) + (today?.grokUsd ?? 0) + (today?.ompUsd ?? 0) + (today?.piUsd ?? 0)
      : wUsd;
    const periodTokens = is24h
      ? claude24Tokens + (today?.codexTokens ?? 0) + (today?.grokTokens ?? 0) + (today?.ompTokens ?? 0) + (today?.piTokens ?? 0)
      : wTokens;

    // Total-cost hero: eyebrow + square period chips on one row (top-right),
    // big period total left / today trailing right below (macOS parity).
    const hero = el("div", "cost-hero");
    const periodLabel = is24h ? "24h" : `${period} ${t("days")}`;
    const head = el("div", "cost-hero-head");
    head.append(el("div", "cost-hero-label", t("totalCostPeriod", { period: periodLabel })));
    const picker = el("div", "period-picker");
    for (const days of PERIODS) {
      const short =
        days === 1 ? "24h"
          : days === 7 ? "7d"
            : days === 30 ? "30d"
              : days === 90 ? "90d"
                : days === 120 ? "120d"
                  : `${days}d`;
      const full = days === 1 ? "24h" : `${days} ${t("days")}`;
      const pill = el("button", `pill${period === days ? " active" : ""}`, short);
      pill.title = full;
      pill.setAttribute("aria-label", full);
      if (period === days) pill.setAttribute("aria-pressed", "true");
      pill.addEventListener("click", () => {
        period = days;
        pinnedDay = null; // new window starts with detail hidden
        localStorage.setItem(PERIOD_KEY, String(days));
        closeDayPanelOnly();  // ngày đã ghim không còn thuộc cửa sổ mới
        render();
        // Top models card listens and re-ranks for the new window.
        window.dispatchEvent(new CustomEvent(PERIOD_CHANGE_EVENT, { detail: { days } }));
      });
      picker.append(pill);
    }
    head.append(picker);
    hero.append(head);
    const heroRow = el("div", "cost-hero-row");
    const left = el("div", "cost-hero-main");
    left.append(el("div", "cost-hero-amount", usd(periodUsd)));
    // Token đậm, phần "· N agent" giữ mờ (macOS costHero).
    const tokenLine = el("div", "cost-hero-tokens");
    tokenLine.append(el("span", "cost-hero-tokens-value", tokens(periodTokens)));
    if (includedSourceCount > 0) {
      tokenLine.append(el("span", "cost-hero-agents",
        ` · ${t("nAgents", { n: includedSourceCount })}`));
    }
    left.append(tokenLine);
    const right = el("div", "cost-hero-today");
    right.append(el("div", "cost-hero-today-label", t("today")));
    right.append(el("div", "cost-hero-today-amount", usd(combined.todayUsd)));
    right.append(el("div", "cost-hero-today-tokens", tokens(combined.todayTokens)));
    heroRow.append(left, right);
    hero.append(heroRow);
    card.append(hero);

    // Chi tiết ngày KHÔNG hiện inline nữa — hover/click cột mở panel phụ, đúng
    // như macOS `CombinedChartCard` (hero → chart → trục → hàng stats).
    if (is24h) {
      card.append(hourChart(claudeHourly));
      card.append(el("div", "footnote", t("hourBarsNote")));
    } else {
      card.append(stackedBarChart(windowDaily, {
        getPinned: () => pinnedDay,
        setPinned: (d) => { pinnedDay = d; },
      }));
      // Axis labels under the bars (start · end of visible window).
      if (windowDaily.length > 0) {
        const axis = el("div", "chart-axis");
        axis.append(el("span", "chart-axis-label", dayLabel(windowDaily[0].date)));
        axis.append(el("span", "chart-axis-label",
          dayLabel(windowDaily[windowDaily.length - 1].date)));
        card.append(axis);
      }
      // Phân bổ theo nguồn KHÔNG nằm ở đây nữa — nó thuộc khối "Chi phí theo".
      // Chỗ này là hàng 4 stat, click/hover mở panel Hoạt động (macOS parity).
      if (includedSourceCount > 0) card.append(compactStatsRow(windowDaily));
    }
  };
  render();
  return card;
}

/** Chuỗi ngày active dài nhất trong window — dùng cho đếm ngược kỷ lục ở
 *  panel Hoạt động (macOS `longestStreak`); khác `streak` (chuỗi hiện tại,
 *  tính lùi từ hôm nay). */
function longestStreakIn(windowDaily: CombinedDay[]): number {
  let longest = 0;
  let run = 0;
  for (const d of windowDaily) {
    if (d.active) { run += 1; longest = Math.max(longest, run); } else { run = 0; }
  }
  return longest;
}

/** Hàng 4 stat dưới biểu đồ: CAO NHẤT · TB/NGÀY · STREAK · NGÀY ACTIVE.
 *  Hover mở panel Hoạt động tạm, click ghim — đúng như macOS `compactStatsRow`.
 *  Phân bổ theo nguồn không ở đây; nó nằm trong khối "Chi phí theo". */
function compactStatsRow(windowDaily: CombinedDay[]): HTMLElement {
  const active = windowDaily.filter((d) => d.active);
  const peak = windowDaily.reduce((m, d) => Math.max(m, d.usd), 0);
  const total = windowDaily.reduce((sum, d) => sum + d.usd, 0);
  const average = active.length > 0 ? total / active.length : 0;

  // Hôm nay chưa hoạt động thì không phá streak — ngày chưa kết thúc.
  let streak = 0;
  let i = windowDaily.length - 1;
  if (i >= 0 && !windowDaily[i].active) i -= 1;
  while (i >= 0 && windowDaily[i].active) { streak += 1; i -= 1; }

  const row = el("div", "chart-stats is-clickable");
  const cell = (label: string, value: string) => {
    const col = el("div", "chart-stat");
    col.append(el("span", "chart-stat-label", label.toUpperCase()));
    col.append(el("span", "chart-stat-value", value));
    return col;
  };
  row.append(cell(t("peakDay"), usdWhole(peak)));
  row.append(el("span", "chart-stat-divider"));
  row.append(cell(t("avgPerActiveDay"), usdWhole(average)));
  row.append(el("span", "chart-stat-divider"));
  row.append(cell(t("streak"), `${streak} ${t("daysWord")}`));
  row.append(el("span", "chart-stat-divider"));
  row.append(cell(t("activeDaysLabel"), `${active.length}/${windowDaily.length}`));
  row.append(el("span", "chart-stat-chevron", "›"));

  // Banded heatmap cần dải ngày LIÊN TỤC (kể cả ngày không active) để dựng
  // đúng lưới tuần Thứ 2 → CN — không filter active như trước.
  const cells = windowDaily.map((d) => ({
    date: d.date, usd: d.usd, tokens: d.tokens, models: d.models,
  }));
  const longestStreak = longestStreakIn(windowDaily);
  const openActivity = (pinned: boolean) =>
    showActivityPanel(cells, peak, average, streak, longestStreak, pinned);
  bindHoverPanel(row, () => openActivity(false));
  row.addEventListener("click", () => openActivity(true));
  return row;
}

function showDayDetail(detail: HTMLElement, day: CombinedDay) {
  detail.textContent = "";
  detail.append(el("div", "day-detail-head",
    `${dayLabel(day.date)} · ${tokens(day.tokens)} · ${usd(day.usd)}`));
  // Compact: merge all models by cost (no per-source headers) — macOS 986f49a8.
  const models = [...day.models].sort((a, b) => (b.usd - a.usd) || (b.tokens - a.tokens));
  if (models.length === 0) {
    // Fallback: source totals when model detail missing.
    if (day.claudeUsd > 0 || day.claudeTokens > 0) {
      detail.append(compactModelRow("claude", "Claude", day.claudeTokens, day.claudeUsd));
    }
    if (day.codexUsd > 0 || day.codexTokens > 0) {
      detail.append(compactModelRow("codex", "Codex", day.codexTokens, day.codexUsd));
    }
    if (day.grokUsd > 0 || day.grokTokens > 0) {
      detail.append(compactModelRow("grok", "Grok", day.grokTokens, day.grokUsd));
    }
    if (day.ompUsd > 0 || day.ompTokens > 0) {
      detail.append(compactModelRow("omp", "Oh My Pi", day.ompTokens, day.ompUsd));
    }
    if (day.piUsd > 0 || day.piTokens > 0) {
      detail.append(compactModelRow("pi", "Pi", day.piTokens, day.piUsd));
    }
    return;
  }
  for (const m of models.slice(0, MAX_DETAIL_MODELS)) {
    detail.append(compactModelRow(m.source, shortModelName(m.name), m.tokens, m.usd));
  }
  const rest = models.slice(MAX_DETAIL_MODELS);
  if (rest.length > 0) {
    const restTokens = rest.reduce((s, m) => s + m.tokens, 0);
    const restUsd = rest.reduce((s, m) => s + m.usd, 0);
    detail.append(compactModelRow(
      "muted",
      t("moreModels", { n: rest.length }),
      restTokens,
      restUsd,
    ));
  }
}

function compactModelRow(
  css: string,
  label: string,
  tokenCount: number,
  amount: number,
): HTMLElement {
  const row = el("div", "model-row compact");
  const left = el("span", "legend-item");
  left.append(el("span", `dot ${css === "muted" ? "muted" : css}`));
  left.append(el("span", "model-name", label));
  row.append(left, el("span", "model-amount", tokensAndUsd(tokenCount, amount)));
  return row;
}

type PinApi = {
  getPinned: () => CombinedDay | null;
  setPinned: (d: CombinedDay | null) => void;
};

/** Stacked per-source bars: Claude → Codex → Grok; height by tokens.
 * Click toggles pin/detail; hover only highlights (never opens detail). */
function stackedBarChart(days: CombinedDay[], pin: PinApi): HTMLElement {
  const max = Math.max(...days.map((d) => d.tokens), 1);
  // Ngữ cảnh cho panel phụ: tổng USD của đúng cửa sổ đang xem + nhãn kỳ.
  const windowUsdTotal = () => days.reduce((sum, d) => sum + d.usd, 0);
  const windowLabel = `${days.length}d`;
  const chart = el("div", `bar-chart${days.length > 45 ? " dense" : ""}`);
  let hoverDay: CombinedDay | null = null;

  const paint = () => {
    // Chi tiết ngày nằm ở panel phụ; ở đây chỉ tô lại trạng thái ghim/hover.
    chart.querySelectorAll(".bar-col").forEach((col) => {
      const elCol = col as HTMLElement;
      const date = elCol.dataset.date;
      const pinned = pin.getPinned();
      elCol.classList.toggle("pinned", !!pinned && date === pinned.date);
      elCol.classList.toggle("hovered", !!hoverDay && date === hoverDay.date);
    });
  };

  for (const day of days) {
    // Chỉ cột ngày mới bấm được — biểu đồ 24h bên macOS không có tương tác.
    const col = el("div", "bar-col is-clickable");
    col.dataset.date = day.date;
    col.title = `${dayLabel(day.date)}: ${tokens(day.tokens)} · ${usd(day.usd)}`;
    if (day.tokens > 0) {
      const heightPct = Math.max((day.tokens / max) * 100, 5);
      const stack = el("div", "bar-stack");
      stack.style.height = `${heightPct}%`;
      const claude = el("div", "bar-seg claude");
      claude.style.flexGrow = String(Math.max(day.claudeTokens, 0.0001));
      const codex = el("div", "bar-seg codex");
      codex.style.flexGrow = String(Math.max(day.codexTokens, 0.0001));
      const grok = el("div", "bar-seg grok");
      grok.style.flexGrow = String(Math.max(day.grokTokens, 0.0001));
      const omp = el("div", "bar-seg omp");
      omp.style.flexGrow = String(Math.max(day.ompTokens, 0.0001));
      const pi = el("div", "bar-seg pi");
      pi.style.flexGrow = String(Math.max(day.piTokens, 0.0001));
      stack.append(claude, codex, grok, omp, pi);
      col.append(stack);
    } else {
      col.append(el("div", "bar-idle"));
    }
    // Hover mở panel phụ transient (macOS parity); rời chuột thì đóng.
    bindHoverPanel(col, () => {
      hoverDay = day;
      showDayPanel(day, windowUsdTotal(), windowLabel, false);
      paint();
    });
    col.addEventListener("mouseleave", () => {
      hoverDay = null;
      paint();
    });
    col.addEventListener("click", () => {
      // Click LUÔN ghim — không toggle. Chỉ nút ✕ trong panel mới đóng được,
      // đúng như macOS `barChart.onTapGesture`.
      pin.setPinned(day);
      showDayPanel(day, windowUsdTotal(), windowLabel, true);
      paint();
    });
    chart.append(col);
  }
  paint();
  return chart;
}

/** 24 Claude-only hour bars (Codex has no hourly resolution); height by tokens. */
function hourChart(hourly: HourlyUsage[]): HTMLElement {
  const max = Math.max(...hourly.map((h) => h.tokens), 1);
  const chart = el("div", "bar-chart");
  for (const hour of hourly) {
    const label = hour.hour.slice(11); // "HH:00"
    const col = el("div", "bar-col");
    col.title = `${label}: ${tokens(hour.tokens)} · ${usd(hour.usd)}`;
    if (hour.tokens > 0) {
      const bar = el("div", "bar-seg claude solo");
      bar.style.height = `${Math.max((hour.tokens / max) * 100, 5)}%`;
      col.append(bar);
    } else {
      col.append(el("div", "bar-idle"));
    }

    chart.append(col);
  }
  return chart;
}

// --- Heatmap card ----------------------------------------------------------

/** Fixed cell 11 + gap 2 (macOS CombinedHeatmapCard). */
const HEAT_CELL = 11;
const HEAT_GAP = 2;
const HEAT_LABEL_W = 28;

/** Week columns that fit at fixed cell size in the available grid width. */
function heatWeeksForWidth(gridWidth: number): number {
  const n = Math.floor((gridWidth + HEAT_GAP) / (HEAT_CELL + HEAT_GAP));
  return Math.max(4, Math.min(52, n));
}

/**
 * Monday-aligned trailing window that fills `weekCount` columns ending today.
 * Dates outside scanned history become empty inactive days (macOS parity).
 */
function heatmapWindow(daily: CombinedDay[], weekCount: number): CombinedDay[] {
  if (daily.length === 0) return [];
  const weeks = Math.max(1, weekCount);
  const last = daily[daily.length - 1];
  const end = new Date(`${last.date}T12:00:00`);
  // JS getDay: 0=Sun … 6=Sat → Mon-first index 0…6
  const mondayIndex = (end.getDay() + 6) % 7;
  const dayCount = (weeks - 1) * 7 + mondayIndex + 1;
  const byDate = new Map(daily.map((d) => [d.date, d]));
  const ymd = (d: Date) => {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  };
  const out: CombinedDay[] = [];
  for (let i = dayCount - 1; i >= 0; i--) {
    const d = new Date(end);
    d.setDate(end.getDate() - i);
    const key = ymd(d);
    const existing = byDate.get(key);
    if (existing) out.push(existing);
    else {
      out.push({
        date: key,
        claudeUsd: 0, claudeTokens: 0,
        codexUsd: 0, codexTokens: 0,
        grokUsd: 0, grokTokens: 0,
        ompUsd: 0, ompTokens: 0,
        piUsd: 0, piTokens: 0,
        kiroUsd: 0, kiroTokens: 0,
        usd: 0, tokens: 0, active: false, models: [],
      });
    }
  }
  return out;
}

export function heatmapCard(combined: Combined): HTMLElement {
  const card = el("section", "card");
  // Fixed cell size; week count fills popover content width (~420 - body pad).
  const contentW = 420 - 32; // .app-body horizontal pad 16×2
  const gridW = Math.max(contentW - HEAT_LABEL_W, HEAT_CELL);
  const weekCount = heatWeeksForWidth(gridW);
  const days = heatmapWindow(combined.daily, weekCount);
  const windowUsd = days.reduce((s, d) => s + d.usd, 0);
  const activeDays = days.filter((d) => d.active).length;
  const dayCount = days.length;

  const head = el("div", "heatmap-head");
  const title =
    currentLang() === "vi"
      ? `Hoạt động ${dayCount} ngày`
      : `${dayCount}-day activity`;
  head.append(el("span", "summary-label", title));
  head.append(el("span", "heatmap-total",
    `${usd(windowUsd)} · ${activeDays} ${t("activeDays")}`));
  card.append(head);

  const body = el("div", "heatmap-body");
  const detail = el("div", "day-detail");
  body.append(weekdayLabels(), heatGrid(days, detail));
  // Design: peak / avg / streak as one mono row under the grid (not side column).
  card.append(body, heatmapStats(days), detail);
  return card;
}

/** Ensure a contiguous trailing window of `n` days (pad empty at the start). */
function trailingDays(daily: CombinedDay[], n: number): CombinedDay[] {
  if (daily.length === 0) return [];
  const last = daily[daily.length - 1];
  const byDate = new Map(daily.map((d) => [d.date, d]));
  const end = new Date(`${last.date}T12:00:00`);
  const out: CombinedDay[] = [];
  const ymd = (d: Date) => {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  };
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(end);
    d.setDate(end.getDate() - i);
    const key = ymd(d);
    const existing = byDate.get(key);
    if (existing) {
      out.push(existing);
    } else {
      out.push({
        date: key,
        claudeUsd: 0, claudeTokens: 0,
        codexUsd: 0, codexTokens: 0,
        grokUsd: 0, grokTokens: 0,
        ompUsd: 0, ompTokens: 0,
        piUsd: 0, piTokens: 0,
        kiroUsd: 0, kiroTokens: 0,
        usd: 0, tokens: 0, active: false, models: [],
      });
    }
  }
  return out;
}

function weekdayLabels(): HTMLElement {
  const labels = currentLang() === "vi"
    ? ["T2", "", "T4", "", "T6", "", "CN"]
    : ["Mon", "", "Wed", "", "Fri", "", "Sun"];
  const col = el("div", "weekday-labels");
  for (const label of labels) col.append(el("div", "weekday-label", label));
  return col;
}

function heatGrid(days: CombinedDay[], detail: HTMLElement): HTMLElement {
  const grid = el("div", "heat-grid");
  // Intensity tracks tokens, not USD — unpriced/non-Claude models cost $0
  // but still burn real tokens, so a USD-based heatmap under-represents them.
  const max = Math.max(...days.map((d) => d.tokens), 1);
  // Monday-first padding for the first column.
  const first = days[0];
  const pad = first ? (new Date(`${first.date}T00:00:00`).getDay() + 6) % 7 : 0;
  const cells: (CombinedDay | null)[] = [...Array(pad).fill(null), ...days];
  while (cells.length % 7 !== 0) cells.push(null);

  let selected: HTMLElement | null = null;
  for (let week = 0; week < cells.length / 7; week++) {
    const col = el("div", "heat-week");
    for (let row = 0; row < 7; row++) {
      const day = cells[week * 7 + row];
      if (!day) {
        col.append(el("div", "heat-cell empty"));
        continue;
      }
      const cell = el("div", "heat-cell");
      const fraction = day.active ? Math.max(day.tokens / max, 0.05) : 0;
      cell.classList.add(heatLevel(fraction));
      if (day === days[days.length - 1]) cell.classList.add("today");
      cell.title = `${dayLabel(day.date)}: ${usd(day.usd)} · ${tokens(day.tokens)}`;
      cell.addEventListener("click", () => {
        if (selected === cell) {
          cell.classList.remove("selected");
          selected = null;
          detail.textContent = "";
          return;
        }
        selected?.classList.remove("selected");
        selected = cell;
        cell.classList.add("selected");
        if (day.active) showDayDetail(detail, day);
        else {
          detail.textContent = "";
          detail.append(el("div", "day-detail-head",
            `${dayLabel(day.date)} · ${t("noActivity")}`));
        }
      });
      col.append(cell);
    }
    grid.append(col);
  }
  return grid;
}

/** 0 → idle track, then four intensity steps (mirrors VocabbyTheme.heatColor). */
function heatLevel(fraction: number): string {
  if (fraction <= 0) return "h0";
  if (fraction <= 0.25) return "h1";
  if (fraction <= 0.5) return "h2";
  if (fraction <= 0.75) return "h3";
  return "h4";
}

function heatmapStats(days: CombinedDay[]): HTMLElement {
  const active = days.filter((d) => d.active);
  const totalUsd = days.reduce((s, d) => s + d.usd, 0);
  const peak = days.reduce<CombinedDay | null>(
    (best, d) => (d.usd > (best?.usd ?? 0) ? d : best), null);
  let streak = 0;
  let i = days.length - 1;
  if (i >= 0 && !days[i].active) i--;
  while (i >= 0 && days[i].active) { streak++; i--; }

  // Design: "CAO NHẤT $X · TB/NGÀY $Y · STREAK N NGÀY"
  const row = el("div", "heat-stats-row");
  const chip = (label: string, value: string) => {
    const box = el("span", "heat-stat-chip");
    box.append(el("span", "heat-stat-label", label.toUpperCase()));
    box.append(el("span", "heat-stat-value", value));
    return box;
  };
  const sep = () => el("span", "heat-stat-sep", "·");
  row.append(
    chip(t("peakDayShort"), peak && peak.usd > 0 ? usd(peak.usd) : "—"),
    sep(),
    chip(t("avgActiveShort"), usd(active.length ? totalUsd / active.length : 0)),
    sep(),
    chip("Streak", `${streak} ${t("streakUnit")}`),
  );
  return row;
}

// --- Top models card --------------------------------------------------------

/** Top models over the chart period chips (not heatmap 120d). Re-renders when
 * `PERIOD_CHANGE_EVENT` fires after a period pill click. */
export function topModelsCard(combined: Combined): HTMLElement {
  const card = el("section", "card top-models-card");

  const periodDays = (): number => {
    let p = Number(localStorage.getItem(PERIOD_KEY)) || 30;
    if (!PERIODS.includes(p)) p = 30;
    return p;
  };

  const render = () => {
    card.textContent = "";
    const p = periodDays();
    const windowDays = trailingDays(combined.daily, p);
    const modelMap = new Map<string, { name: string; usd: number; tokens: number; source: string }>();
    for (const d of windowDays) {
      for (const m of d.models) {
        const k = `${m.source}:${m.name}`;
        const cur = modelMap.get(k) ?? { name: m.name, usd: 0, tokens: 0, source: m.source };
        cur.usd += m.usd;
        cur.tokens += m.tokens;
        modelMap.set(k, cur);
      }
    }
    const top = [...modelMap.values()]
      .sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd))
      .slice(0, 6);
    if (top.length === 0) return;

    const title = p === 1
      ? (currentLang() === "vi" ? "Model dùng nhiều (24h)" : "Top models (24h)")
      : (currentLang() === "vi"
        ? `Model dùng nhiều (${p} ngày)`
        : `Top models (${p} days)`);
    card.append(el("div", "summary-label", title));
    const windowTokens = Math.max(
      windowDays.reduce((s, d) => s + d.tokens, 0),
      top.reduce((s, m) => s + m.tokens, 0),
      1,
    );

    // Design row: brand icon · name (flex) | fixed 84px bar | fixed 84px amount.
    for (const model of top) {
      const row = el("div", "top-model-row");
      const left = el("span", "top-model-left");
      left.append(el("span", `dot ${model.source}`), el("span", "top-model-name", shortModelName(model.name)));
      row.append(left);
      const track = el("div", "model-track");
      const fill = el("div", `model-fill ${model.source}`);
      fill.style.width = `${Math.max((model.tokens / windowTokens) * 100, 1)}%`;
      track.append(fill);
      row.append(track);
      row.append(el("span", "top-model-amount", tokensAndUsd(model.tokens, model.usd)));
      card.append(row);
    }
  };

  render();
  window.addEventListener(PERIOD_CHANGE_EVENT, render);
  return card;
}


/** Compact model label for dense rows (macOS AllUsageFormat.shortName parity). */
function shortModelName(name: string): string {
  if (name.length <= 28) return name;
  return name.slice(0, 26) + "…";
}
