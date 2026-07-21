// The "All" overview tab — port of the macOS AllUsageOverview cards
// (remake polish d2852ed4 / 4852ab68 / 986f49a8):
// total-cost hero + period picker + stacked bars + cost share bar,
// click-to-pin day detail (compact model rows), 120-day heatmap, top models.

import {
  Combined, CombinedDay, HourlyUsage,
  usd, tokens, tokensShort, dayLabel,
} from "./usage";
import { t, currentLang } from "./i18n";

const PERIOD_KEY = "birdnion.allChartDays";
const PERIODS = [1, 7, 30, 90]; // 1 = the 24h hourly view
/** Heatmap / top-models window — macOS CombinedUsageReport windowDays. */
const HEATMAP_DAYS = 120;
/** Cap model rows in day-detail so the breakdown stays shorter than the chart. */
const MAX_DETAIL_MODELS = 6;

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function legendDot(cssClass: string, label: string) {
  const item = el("span", "legend-item");
  item.append(el("span", `dot ${cssClass}`), el("span", "legend-label", label));
  return item;
}

// --- Chart card -----------------------------------------------------------

export function chartCard(combined: Combined, claudeHourly: HourlyUsage[]): HTMLElement {
  const card = el("section", "card");
  let period = Number(localStorage.getItem(PERIOD_KEY)) || 30;
  if (!PERIODS.includes(period)) period = 30;
  // Click-to-pin day detail (macOS pinnedDay) — no auto last-active fallback.
  let pinnedDay: CombinedDay | null = null;

  const render = () => {
    card.textContent = "";
    const windowDaily = combined.daily.slice(-period);
    const wUsd = windowDaily.reduce((s, d) => s + d.usd, 0);
    const wTokens = windowDaily.reduce((s, d) => s + d.tokens, 0);
    const wClaudeTokens = windowDaily.reduce((s, d) => s + d.claudeTokens, 0);
    const wCodexTokens = windowDaily.reduce((s, d) => s + d.codexTokens, 0);
    const wGrokTokens = windowDaily.reduce((s, d) => s + d.grokTokens, 0);
    const wClaudeUsd = windowDaily.reduce((s, d) => s + d.claudeUsd, 0);
    const wCodexUsd = windowDaily.reduce((s, d) => s + d.codexUsd, 0);
    const wGrokUsd = windowDaily.reduce((s, d) => s + d.grokUsd, 0);
    const is24h = period === 1;
    const claude24Usd = claudeHourly.reduce((s, h) => s + h.usd, 0);
    const claude24Tokens = claudeHourly.reduce((s, h) => s + h.tokens, 0);
    const today = combined.daily[combined.daily.length - 1];

    const periodUsd = is24h
      ? claude24Usd + (today?.codexUsd ?? 0) + (today?.grokUsd ?? 0)
      : wUsd;
    const periodTokens = is24h
      ? claude24Tokens + (today?.codexTokens ?? 0) + (today?.grokTokens ?? 0)
      : wTokens;

    // Total-cost hero (macOS mockup): big period total left, today trailing right.
    const hero = el("div", "cost-hero");
    const periodLabel = is24h ? "24h" : `${period} ${t("days")}`;
    hero.append(el("div", "cost-hero-label", t("totalCostPeriod", { period: periodLabel })));
    const heroRow = el("div", "cost-hero-row");
    const left = el("div", "cost-hero-main");
    left.append(el("div", "cost-hero-amount", usd(periodUsd)));
    left.append(el("div", "cost-hero-tokens", tokens(periodTokens)));
    const right = el("div", "cost-hero-today");
    right.append(el("div", "cost-hero-today-label", t("today")));
    right.append(el("div", "cost-hero-today-amount", usd(combined.todayUsd)));
    right.append(el("div", "cost-hero-today-tokens", tokens(combined.todayTokens)));
    heroRow.append(left, right);
    hero.append(heroRow);
    card.append(hero);

    // Period pills.
    const picker = el("div", "period-picker");
    for (const days of PERIODS) {
      const pill = el("button", `pill${period === days ? " active" : ""}`,
        days === 1 ? "24h" : `${days} ${t("days")}`);
      pill.addEventListener("click", () => {
        period = days;
        pinnedDay = null;
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
        legendDot("claude", `Claude ${tokensShort(claude24Tokens)}`),
        legendDot("codex", `${t("codexToday")} ${tokensShort(today?.codexTokens ?? 0)}`),
        legendDot("grok", `Grok ${tokensShort(today?.grokTokens ?? 0)}`));
      card.append(legend, detail);
      card.append(el("div", "footnote", t("hourBarsNote")));
    } else {
      card.append(stackedBarChart(windowDaily, detail, {
        getPinned: () => pinnedDay,
        setPinned: (d) => { pinnedDay = d; },
      }));
      const legend = el("div", "legend");
      legend.append(
        legendDot("claude", `Claude ${tokensShort(wClaudeTokens)}`),
        legendDot("codex", `Codex ${tokensShort(wCodexTokens)}`),
        legendDot("grok", `Grok ${tokensShort(wGrokTokens)}`));
      card.append(legend);
      // Cost share bar + rows (macOS sourceShareRows) — period USD split.
      card.append(sourceShareSection([
        { name: "Claude", usd: wClaudeUsd, css: "claude" },
        { name: "Codex", usd: wCodexUsd, css: "codex" },
        { name: "Grok", usd: wGrokUsd, css: "grok" },
      ]));
      if (pinnedDay && windowDaily.some((d) => d.date === pinnedDay!.date)) {
        showDayDetail(detail, pinnedDay);
      }
      card.append(detail);
      card.append(el("div", "footnote", t("estFootnote")));
    }
  };
  render();
  return card;
}

/** Full-width cost-share capsule + compact % / $ rows (view-only over totals). */
function sourceShareSection(
  rows: { name: string; usd: number; css: string }[],
): HTMLElement {
  const wrap = el("div", "share-section");
  const active = rows.filter((r) => r.usd > 0);
  if (active.length === 0) return wrap;
  const total = Math.max(active.reduce((s, r) => s + r.usd, 0), 0.01);

  const bar = el("div", "share-bar");
  for (const r of active) {
    const seg = el("div", `share-seg ${r.css}`);
    const pct = Math.max((r.usd / total) * 100, 1.5);
    seg.style.flexGrow = String(pct);
    seg.style.flexBasis = "0";
    bar.append(seg);
  }
  wrap.append(bar);

  const list = el("div", "share-list");
  active.forEach((r, i) => {
    if (i > 0) list.append(el("div", "share-divider"));
    const row = el("div", "share-row");
    const left = el("span", "legend-item");
    left.append(el("span", `dot ${r.css}`), el("span", "share-name", r.name));
    const sharePct = Math.round((r.usd / total) * 100);
    row.append(
      left,
      el("span", "share-pct", `${sharePct}%`),
      el("span", "share-usd", usd(r.usd)),
    );
    list.append(row);
  });
  wrap.append(list);
  return wrap;
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
  row.append(left, el("span", "model-amount", `${tokensShort(tokenCount)} · ${usd(amount)}`));
  return row;
}

type PinApi = {
  getPinned: () => CombinedDay | null;
  setPinned: (d: CombinedDay | null) => void;
};

/** Stacked per-source bars: Claude → Codex → Grok; height by tokens.
 * Click toggles pin; hover temporarily previews detail. */
function stackedBarChart(days: CombinedDay[], detail: HTMLElement, pin: PinApi): HTMLElement {
  const max = Math.max(...days.map((d) => d.tokens), 1);
  const chart = el("div", `bar-chart${days.length > 45 ? " dense" : ""}`);
  let hoverDay: CombinedDay | null = null;

  const paintDetail = () => {
    const day = hoverDay ?? pin.getPinned();
    if (day) showDayDetail(detail, day);
    else detail.textContent = "";
    // Highlight pinned bar.
    chart.querySelectorAll(".bar-col").forEach((col) => {
      const elCol = col as HTMLElement;
      const date = elCol.dataset.date;
      const pinned = pin.getPinned();
      elCol.classList.toggle("pinned", !!pinned && date === pinned.date);
      elCol.classList.toggle("hovered", !!hoverDay && date === hoverDay.date);
    });
  };

  for (const day of days) {
    const col = el("div", "bar-col");
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
      stack.append(claude, codex, grok);
      col.append(stack);
    } else {
      col.append(el("div", "bar-idle"));
    }
    col.addEventListener("mouseenter", () => {
      hoverDay = day;
      paintDetail();
    });
    col.addEventListener("mouseleave", () => {
      hoverDay = null;
      paintDetail();
    });
    col.addEventListener("click", () => {
      const cur = pin.getPinned();
      pin.setPinned(cur && cur.date === day.date ? null : day);
      paintDetail();
    });
    chart.append(col);
  }
  paintDetail();
  return chart;
}

/** 24 Claude-only hour bars (Codex has no hourly resolution); height by tokens. */
function hourChart(hourly: HourlyUsage[], detail: HTMLElement): HTMLElement {
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
    col.addEventListener("mouseenter", () => {
      detail.textContent = "";
      detail.append(el("div", "day-detail-head",
        `${label} · ${tokens(hour.tokens)} · ${usd(hour.usd)}`));
    });
    col.addEventListener("mouseleave", () => {
      detail.textContent = "";
    });
    chart.append(col);
  }
  return chart;
}

// --- Heatmap card ----------------------------------------------------------

export function heatmapCard(combined: Combined): HTMLElement {
  const card = el("section", "card");
  // Use trailing HEATMAP_DAYS (pad if scanner returns fewer).
  const days = trailingDays(combined.daily, HEATMAP_DAYS);
  const windowUsd = days.reduce((s, d) => s + d.usd, 0);
  const activeDays = days.filter((d) => d.active).length;

  const head = el("div", "heatmap-head");
  head.append(el("span", "summary-label", t("activity120")));
  head.append(el("span", "heatmap-total",
    `${usd(windowUsd)} · ${activeDays} ${t("activeDays")}`));
  card.append(head);

  const body = el("div", "heatmap-body");
  const detail = el("div", "day-detail");
  const stats = heatmapStats(days);
  body.append(weekdayLabels(), heatGrid(days, detail), stats);
  card.append(body, detail);
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

  const col = el("div", "heat-stats");
  const stat = (label: string, value: string) => {
    const box = el("div", "stat");
    box.append(el("div", "summary-label", label), el("div", "stat-value", value));
    return box;
  };
  col.append(stat(t("peakDay"), peak && peak.usd > 0
    ? `${usd(peak.usd)} · ${dayLabel(peak.date)}` : "—"));
  col.append(stat(t("avgActive"), usd(active.length ? totalUsd / active.length : 0)));
  col.append(stat("Streak", `${streak} ${t("streakUnit")}`));
  return col;
}

// --- Top models card --------------------------------------------------------

export function topModelsCard(combined: Combined): HTMLElement {
  const card = el("section", "card top-models-card");
  card.append(el("div", "summary-label", t("topModels120")));
  // Top models over the trailing heatmap window (token share of that window).
  const days = trailingDays(combined.daily, HEATMAP_DAYS);
  const modelMap = new Map<string, { name: string; usd: number; tokens: number; source: string }>();
  for (const d of days) {
    for (const m of d.models) {
      const k = `${m.source}:${m.name}`;
      const e = modelMap.get(k);
      if (e) { e.usd += m.usd; e.tokens += m.tokens; }
      else modelMap.set(k, { name: m.name, usd: m.usd, tokens: m.tokens, source: m.source });
    }
  }
  const top = [...modelMap.values()]
    .sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd))
    .slice(0, 6);
  const total = Math.max(top.reduce((s, m) => s + m.tokens, 0), 1);
  // Prefer window token total for bar width share (macOS).
  const windowTokens = Math.max(days.reduce((s, d) => s + d.tokens, 0), total);

  for (const model of top) {
    const row = el("div", "top-model-row");
    const head = el("div", "top-model-head");
    const left = el("span", "legend-item");
    left.append(
      el("span", `dot ${model.source}`),
      el("span", "top-model-name", shortModelName(model.name)),
    );
    head.append(
      left,
      el("span", "top-model-amount", `${tokensShort(model.tokens)} · ${usd(model.usd)}`),
    );
    const track = el("div", "model-track");
    const fill = el("div", `model-fill ${model.source}`);
    fill.style.width = `${Math.max((model.tokens / windowTokens) * 100, 1)}%`;
    track.append(fill);
    row.append(head, track);
    card.append(row);
  }
  return card;
}

/** Compact model label for dense rows (macOS AllUsageFormat.shortName parity). */
function shortModelName(name: string): string {
  if (name.length <= 28) return name;
  return name.slice(0, 26) + "…";
}
