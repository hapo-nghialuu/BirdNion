// The "All" overview tab — port of the macOS AllUsageOverview cards:
// chart card with a 24h/7/30/90-day period picker and per-source stacked
// bars, a clickable 90-day heatmap with peak/avg/streak stats, and the
// merged top-models list.

import {
  Combined, CombinedDay, HourlyUsage,
  usd, tokens, tokensShort, dayLabel,
} from "./usage";
import { t, currentLang } from "./i18n";

const PERIOD_KEY = "birdnion.allChartDays";
const PERIODS = [1, 7, 30, 90]; // 1 = the 24h hourly view

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function summaryColumn(label: string, amount: number, tokenCount: number, trailing = false) {
  const col = el("div", `summary-col${trailing ? " trailing" : ""}`);
  col.append(el("div", "summary-label", label));
  col.append(el("div", "summary-amount", usd(amount)));
  col.append(el("div", "summary-tokens", tokens(tokenCount)));
  return col;
}

function legendDot(cssClass: string, label: string) {
  const item = el("span", "legend-item");
  item.append(el("span", `dot ${cssClass}`), el("span", "legend-label", label));
  return item;
}

function sourceRow(cssClass: string, label: string, amount: number, tokenCount: number) {
  const row = el("div", "source-row");
  const left = el("span", "legend-item");
  left.append(el("span", `dot ${cssClass}`), el("span", "legend-label", label));
  row.append(left, el("span", "source-amount", `${usd(amount)} · ${tokensShort(tokenCount)}`));
  return row;
}

// --- Chart card -----------------------------------------------------------

export function chartCard(combined: Combined, claudeHourly: HourlyUsage[]): HTMLElement {
  const card = el("section", "card");
  let period = Number(localStorage.getItem(PERIOD_KEY)) || 30;
  if (!PERIODS.includes(period)) period = 30;

  const render = () => {
    card.textContent = "";
    const windowDaily = combined.daily.slice(-period);
    const wUsd = windowDaily.reduce((s, d) => s + d.usd, 0);
    const wTokens = windowDaily.reduce((s, d) => s + d.tokens, 0);
    const wClaude = windowDaily.reduce((s, d) => s + d.claudeUsd, 0);
    const wCodex = windowDaily.reduce((s, d) => s + d.codexUsd, 0);
    const wGrok = windowDaily.reduce((s, d) => s + d.grokUsd, 0);
    const is24h = period === 1;
    const claude24Usd = claudeHourly.reduce((s, h) => s + h.usd, 0);
    const claude24Tokens = claudeHourly.reduce((s, h) => s + h.tokens, 0);
    const today = combined.daily[combined.daily.length - 1];

    const summary = el("div", "summary-row");
    summary.append(summaryColumn(t("today"), combined.todayUsd, combined.todayTokens));
    summary.append(summaryColumn(
      is24h ? "24h" : `${period} ${t("days")}`,
      is24h
        ? claude24Usd + (today?.codexUsd ?? 0) + (today?.grokUsd ?? 0)
        : wUsd,
      is24h
        ? claude24Tokens + (today?.codexTokens ?? 0) + (today?.grokTokens ?? 0)
        : wTokens,
      true));
    card.append(summary);

    // Period pills.
    const picker = el("div", "period-picker");
    for (const days of PERIODS) {
      const pill = el("button", `pill${period === days ? " active" : ""}`,
        days === 1 ? "24h" : `${days} ${t("days")}`);
      pill.addEventListener("click", () => {
        period = days;
        localStorage.setItem(PERIOD_KEY, String(days));
        render();
      });
      picker.append(pill);
    }
    card.append(picker);

    const detail = el("div", "day-detail");
    if (is24h) {
      card.append(hourChart(claudeHourly, detail));
      const legend = el("div", "legend");
      legend.append(
        legendDot("claude", `Claude ${usd(claude24Usd)}`),
        legendDot("codex", `${t("codexToday")} ${usd(today?.codexUsd ?? 0)}`),
        legendDot("grok", `Grok ${usd(today?.grokUsd ?? 0)}`));
      card.append(legend, detail);
      card.append(el("div", "footnote", t("hourBarsNote")));
    } else {
      card.append(stackedBarChart(windowDaily, detail));
      const legend = el("div", "legend");
      legend.append(
        legendDot("claude", `Claude ${usd(wClaude)}`),
        legendDot("codex", `Codex ${usd(wCodex)}`),
        legendDot("grok", `Grok ${usd(wGrok)}`));
      card.append(legend, detail);
      const lastActive = [...windowDaily].reverse().find((d) => d.active);
      if (lastActive) showDayDetail(detail, lastActive);
      card.append(el("div", "est-total", `${t("estTotal", { n: period })}: ${usd(wUsd)}`));
      card.append(el("div", "footnote", t("estFootnote")));
    }
  };
  render();
  return card;
}

function showDayDetail(detail: HTMLElement, day: CombinedDay) {
  detail.textContent = "";
  detail.append(el("div", "day-detail-head",
    `${dayLabel(day.date)} · ${usd(day.usd)} · ${tokens(day.tokens)}`));
  if (day.claudeUsd > 0 || day.claudeTokens > 0) {
    detail.append(sourceRow("claude", "Claude", day.claudeUsd, day.claudeTokens));
    appendModelRows(detail, day, "claude");
  }
  if (day.codexUsd > 0 || day.codexTokens > 0) {
    detail.append(sourceRow("codex", "Codex", day.codexUsd, day.codexTokens));
    appendModelRows(detail, day, "codex");
  }
  if (day.grokUsd > 0 || day.grokTokens > 0) {
    detail.append(sourceRow("grok", "Grok", day.grokUsd, day.grokTokens));
    appendModelRows(detail, day, "grok");
  }
}

/** Indented per-model lines under a source row (top 5/day from the scanner),
 * so "Claude" isn't one opaque figure — mirrors the macOS DaySourceModelRows. */
function appendModelRows(detail: HTMLElement, day: CombinedDay, source: "claude" | "codex" | "grok") {
  for (const m of day.models.filter((x) => x.source === source)) {
    const row = el("div", "model-row");
    row.append(
      el("span", "model-name", m.name),
      el("span", "model-amount", `${usd(m.usd)} · ${tokensShort(m.tokens)}`));
    detail.append(row);
  }
}

/** Stacked per-source bars: Claude → Codex → Grok. */
function stackedBarChart(days: CombinedDay[], detail: HTMLElement): HTMLElement {
  const max = Math.max(...days.map((d) => d.usd), 0.01);
  const chart = el("div", `bar-chart${days.length > 45 ? " dense" : ""}`);
  for (const day of days) {
    const col = el("div", "bar-col");
    col.title = `${dayLabel(day.date)}: ${usd(day.usd)} · ${tokens(day.tokens)}`;
    if (day.usd > 0) {
      const heightPct = Math.max((day.usd / max) * 100, 5);
      const stack = el("div", "bar-stack");
      stack.style.height = `${heightPct}%`;
      const claude = el("div", "bar-seg claude");
      claude.style.flexGrow = String(Math.max(day.claudeUsd, 0.0001));
      const codex = el("div", "bar-seg codex");
      codex.style.flexGrow = String(Math.max(day.codexUsd, 0.0001));
      const grok = el("div", "bar-seg grok");
      grok.style.flexGrow = String(Math.max(day.grokUsd, 0.0001));
      stack.append(claude, codex, grok);
      col.append(stack);
    } else {
      col.append(el("div", "bar-idle"));
    }
    col.addEventListener("mouseenter", () => showDayDetail(detail, day));
    chart.append(col);
  }
  return chart;
}

/** 24 Claude-only hour bars (Codex has no hourly resolution). */
function hourChart(hourly: HourlyUsage[], detail: HTMLElement): HTMLElement {
  const max = Math.max(...hourly.map((h) => h.usd), 1e-6);
  const chart = el("div", "bar-chart");
  for (const hour of hourly) {
    const label = hour.hour.slice(11); // "HH:00"
    const col = el("div", "bar-col");
    col.title = `${label}: ${usd(hour.usd)} · ${tokens(hour.tokens)}`;
    if (hour.usd > 0) {
      const bar = el("div", "bar-seg claude solo");
      bar.style.height = `${Math.max((hour.usd / max) * 100, 5)}%`;
      col.append(bar);
    } else {
      col.append(el("div", "bar-idle"));
    }
    col.addEventListener("mouseenter", () => {
      detail.textContent = "";
      detail.append(el("div", "day-detail-head",
        `${label} · ${usd(hour.usd)} · ${tokens(hour.tokens)}`));
    });
    chart.append(col);
  }
  return chart;
}

// --- Heatmap card ----------------------------------------------------------

export function heatmapCard(combined: Combined): HTMLElement {
  const card = el("section", "card");
  const head = el("div", "heatmap-head");
  head.append(el("span", "summary-label", t("activity90")));
  head.append(el("span", "heatmap-total",
    `${usd(combined.totalUsd)} · ${combined.activeDays} ${t("activeDays")}`));
  card.append(head);

  const body = el("div", "heatmap-body");
  const detail = el("div", "day-detail");
  body.append(weekdayLabels(), heatGrid(combined, detail), statsColumn(combined));
  card.append(body, detail);
  return card;
}

function weekdayLabels(): HTMLElement {
  const labels = currentLang() === "vi"
    ? ["T2", "", "T4", "", "T6", "", "CN"]
    : ["Mon", "", "Wed", "", "Fri", "", "Sun"];
  const col = el("div", "weekday-labels");
  for (const label of labels) col.append(el("div", "weekday-label", label));
  return col;
}

function heatGrid(combined: Combined, detail: HTMLElement): HTMLElement {
  const grid = el("div", "heat-grid");
  const days = combined.daily;
  const max = Math.max(...days.map((d) => d.usd), 0.01);
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
      const fraction = day.active ? Math.max(day.usd / max, 0.05) : 0;
      cell.classList.add(heatLevel(fraction));
      if (day === days[days.length - 1]) cell.classList.add("today");
      cell.title = `${dayLabel(day.date)}: ${usd(day.usd)} · ${tokens(day.tokens)}`;
      cell.addEventListener("click", () => {
        // Click pins the per-source breakdown; clicking again dismisses it.
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

function statsColumn(combined: Combined): HTMLElement {
  const col = el("div", "heat-stats");
  const stat = (label: string, value: string) => {
    const box = el("div", "stat");
    box.append(el("div", "summary-label", label), el("div", "stat-value", value));
    return box;
  };
  col.append(stat(t("peakDay"), combined.peakDate
    ? `${usd(combined.peakUsd)} · ${dayLabel(combined.peakDate)}` : "—"));
  col.append(stat(t("avgActive"), usd(combined.avgActiveUsd)));
  col.append(stat("Streak", `${combined.streakDays} ${t("streakUnit")}`));
  return col;
}

// --- Top models card --------------------------------------------------------

export function topModelsCard(combined: Combined): HTMLElement {
  const card = el("section", "card top-models-card");
  card.append(el("div", "summary-label", t("topModels")));
  // Denominator is the 90-day window TOTAL (not the top model's own USD), so
  // bar width reflects each model's actual share of spend — macOS parity
  // fix (previously divided by max, so the top row was always ~100%).
  const total = Math.max(combined.totalUsd, 0.01);
  for (const model of combined.topModels) {
    const row = el("div", "top-model-row");
    const head = el("div", "top-model-head");
    const left = el("span", "legend-item");
    left.append(
      el("span", `dot ${model.source}`),
      el("span", "top-model-name", shortModelName(model.name)),
    );
    head.append(
      left,
      el("span", "top-model-amount", `${usd(model.usd)} · ${tokensShort(model.tokens)}`),
    );
    const track = el("div", "model-track");
    const fill = el("div", `model-fill ${model.source}`);
    fill.style.width = `${Math.max((model.usd / total) * 100, 1)}%`;
    track.append(fill);
    row.append(head, track);
    card.append(row);
  }
  return card;
}

/** Compact model label for dense rows (macOS AllUsageFormat.shortName parity). */
function shortModelName(name: string): string {
  // Drop common date/version noise: "claude-haiku-4-5-20251001" → keep as-is if short
  if (name.length <= 28) return name;
  return name.slice(0, 26) + "…";
}
