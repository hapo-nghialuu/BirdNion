// Types mirroring src-tauri/src/usage.rs (serde camelCase) plus the
// combined-report math ported from the macOS `CombinedUsageReport.build`
// (Claude + Codex + Grok).

import { t } from "./i18n.ts";

export type DailyModel = { name: string; usd: number; tokens: number };
export type DailyUsage = { date: string; usd: number; tokens: number; models: DailyModel[] };
export type HourlyUsage = { hour: string; usd: number; tokens: number };
export type UsageReport = {
  todayUsd: number;
  todayTokens: number;
  last30Usd: number;
  last30Tokens: number;
  daily: DailyUsage[];
  hourly: HourlyUsage[];
  topModel: string | null;
  /** Data Confidence Pass metadata — optional so older cached reports (or a
   * command result predating this field) still type-check. `undefined`
   * reads the same as `false`/`null` at every call site below. */
  included?: boolean;
  live?: boolean;
  scannedAt?: number | null;
};

/** Resolve one streamed local-cost refresh without confusing two different
 * `null` cases. A source absent from the canonical enabled set is removed;
 * an enabled source whose scan failed keeps its last-good report. */
export function resolveRefreshedUsageReport(
  previous: UsageReport | null,
  fresh: UsageReport | null,
  canonicalEnabled: boolean | null,
): UsageReport | null {
  // Unknown authorization must fail closed: a transient config/IPC failure
  // cannot authorize scanning or keep previously-visible private usage.
  if (canonicalEnabled !== true) return null;
  return fresh ?? previous;
}

/** Cost sources for confidence badges and spend attribution. */
export type UsageSourceId = "claude" | "codex" | "grok" | "omp" | "pi" | "kiro";
export const USAGE_SOURCE_IDS: readonly UsageSourceId[] = [
  "claude", "codex", "grok", "kiro", "omp", "pi",
];
export const KIRO_AGGREGATE_MODEL_NAME = "Other";
export type ScanConfidence = "live" | "history" | "unavailable";

/** Kiro's residual conservation bucket is not a model. Source scoping keeps a
 * real model named `Other` from Claude/Codex/etc. visible. */
export function isKiroSyntheticAggregate(
  model: Pick<CombinedModel, "source" | "name">,
): boolean {
  return model.source === "kiro" && model.name === KIRO_AGGREGATE_MODEL_NAME;
}

/** Data Confidence Pass: classify a source's report into the compact
 * All-tab badge state. Pure function of the report's own fields — no
 * network/clock access beyond what the caller already fetched. */
export function scanConfidence(report: UsageReport | null | undefined): ScanConfidence {
  if (!report?.included) return "unavailable";
  return report.live ? "live" : "history";
}

/** "vừa quét" / "N phút trước" / "N giờ trước" freshness label from a
 * source's `scannedAt` (epoch millis). `null` when there is nothing to show
 * (never scanned) — callers render a placeholder instead. */
export function scanFreshness(scannedAt: number | null | undefined): string | null {
  if (scannedAt == null || !Number.isFinite(scannedAt) || scannedAt <= 0) return null;
  const seconds = Math.max(0, Math.floor((Date.now() - scannedAt) / 1000));
  if (seconds < 5) return t("time.justUpdated");
  if (seconds < 60) return t("time.secondsAgo", { n: seconds });
  if (seconds < 3600) return t("time.minutesAgo", { n: Math.floor(seconds / 60) });
  return t("time.hoursAgo", { n: Math.floor(seconds / 3600) });
}

/** Design badge freshness: "vừa xong" / "2 phút" / "3 giờ" (no "trước"). */
export function badgeFreshness(scannedAt: number | null | undefined): string | null {
  if (scannedAt == null || !Number.isFinite(scannedAt) || scannedAt <= 0) return null;
  const seconds = Math.max(0, Math.floor((Date.now() - scannedAt) / 1000));
  if (seconds < 60) return t("confidence.fresh.justNow");
  if (seconds < 3600) return t("confidence.fresh.minutes", { n: Math.floor(seconds / 60) });
  if (seconds < 86400) return t("confidence.fresh.hours", { n: Math.floor(seconds / 3600) });
  return t("confidence.fresh.days", { n: Math.floor(seconds / 86400) });
}

export type CombinedModel = {
  name: string;
  usd: number;
  tokens: number;
  source: UsageSourceId;
};

export type CombinedDay = {
  date: string;
  claudeUsd: number;
  claudeTokens: number;
  codexUsd: number;
  codexTokens: number;
  grokUsd: number;
  grokTokens: number;
  ompUsd: number;
  ompTokens: number;
  piUsd: number;
  piTokens: number;
  kiroUsd: number;
  kiroTokens: number;
  usd: number;
  tokens: number;
  active: boolean;
  models: CombinedModel[];
};

export type SourceUsageTotals = { usd: number; tokens: number };

/** Canonical field mapping for every local-cost source. Keeping this in one
 * place prevents a newly supported source from silently disappearing from
 * cards, digests, or provider budgets. */
export function combinedDaySourceUsage(
  day: CombinedDay,
  source: UsageSourceId,
): SourceUsageTotals {
  switch (source) {
    case "claude": return { usd: day.claudeUsd, tokens: day.claudeTokens };
    case "codex": return { usd: day.codexUsd, tokens: day.codexTokens };
    case "grok": return { usd: day.grokUsd, tokens: day.grokTokens };
    case "kiro": return { usd: day.kiroUsd, tokens: day.kiroTokens };
    case "omp": return { usd: day.ompUsd, tokens: day.ompTokens };
    case "pi": return { usd: day.piUsd, tokens: day.piTokens };
  }
}

export function combinedWindowSourceTotals(
  days: readonly CombinedDay[],
): Record<UsageSourceId, SourceUsageTotals> {
  const totals = Object.fromEntries(
    USAGE_SOURCE_IDS.map((source) => [source, { usd: 0, tokens: 0 }]),
  ) as Record<UsageSourceId, SourceUsageTotals>;
  for (const day of days) {
    for (const source of USAGE_SOURCE_IDS) {
      const usage = combinedDaySourceUsage(day, source);
      totals[source].usd += usage.usd;
      totals[source].tokens += usage.tokens;
    }
  }
  return totals;
}

export function activeUsageSourceIds(days: readonly CombinedDay[]): UsageSourceId[] {
  const totals = combinedWindowSourceTotals(days);
  return USAGE_SOURCE_IDS.filter((id) => totals[id].usd > 0 || totals[id].tokens > 0);
}

export type Combined = {
  daily: CombinedDay[];
  todayUsd: number;
  todayTokens: number;
  last30Usd: number;
  last30Tokens: number;
  totalUsd: number;
  totalTokens: number;
  activeDays: number;
  peakUsd: number;
  peakDate: string | null;
  avgActiveUsd: number;
  streakDays: number;
  topModels: CombinedModel[];
};

/** Merge scanners' daily arrays by calendar-day string. */
export function combine(
  claude: UsageReport | null,
  codex: UsageReport | null,
  grok: UsageReport | null = null,
  omp: UsageReport | null = null,
  pi: UsageReport | null = null,
  kiro: UsageReport | null = null,
): Combined {
  const byDate = new Map<string, CombinedDay>();
  const seed = (r: UsageReport | null, source: UsageSourceId) => {
    for (const d of r?.daily ?? []) {
      let day = byDate.get(d.date);
      if (!day) {
        day = {
          date: d.date,
          claudeUsd: 0, claudeTokens: 0,
          codexUsd: 0, codexTokens: 0,
          grokUsd: 0, grokTokens: 0,
          ompUsd: 0, ompTokens: 0,
          piUsd: 0, piTokens: 0,
          kiroUsd: 0, kiroTokens: 0,
          usd: 0, tokens: 0, active: false, models: [],
        };
        byDate.set(d.date, day);
      }
      if (source === "claude") { day.claudeUsd += d.usd; day.claudeTokens += d.tokens; }
      else if (source === "codex") { day.codexUsd += d.usd; day.codexTokens += d.tokens; }
      else if (source === "grok") { day.grokUsd += d.usd; day.grokTokens += d.tokens; }
      else if (source === "omp") { day.ompUsd += d.usd; day.ompTokens += d.tokens; }
      else if (source === "pi") { day.piUsd += d.usd; day.piTokens += d.tokens; }
      else if (source === "kiro") { day.kiroUsd += d.usd; day.kiroTokens += d.tokens; }
      day.usd = day.claudeUsd + day.codexUsd + day.grokUsd + day.ompUsd + day.piUsd + day.kiroUsd;
      day.tokens = day.claudeTokens + day.codexTokens + day.grokTokens + day.ompTokens
        + day.piTokens + day.kiroTokens;
      day.active = day.usd > 0 || day.tokens > 0;
      for (const m of d.models) {
        const existing = day.models.find((x) => x.source === source && x.name === m.name);
        if (existing) { existing.usd += m.usd; existing.tokens += m.tokens; }
        else { day.models.push({ name: m.name, usd: m.usd, tokens: m.tokens, source }); }
      }
    }
  };
  seed(claude, "claude");
  seed(codex, "codex");
  seed(grok, "grok");
  seed(omp, "omp");
  seed(pi, "pi");
  seed(kiro, "kiro");
  const daily = [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
  // Token-first ranking (matches macOS All chart + top-models list).
  for (const d of daily) d.models.sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd));
  const today = daily[daily.length - 1];
  const totalUsd = daily.reduce((s, d) => s + d.usd, 0);
  const totalTokens = daily.reduce((s, d) => s + d.tokens, 0);
  const active = daily.filter((d) => d.active);
  const peak = daily.reduce<CombinedDay | null>(
    (best, d) => (d.usd > (best?.usd ?? 0) ? d : best), null);

  let streak = 0;
  let i = daily.length - 1;
  if (i >= 0 && !daily[i].active) i--;
  while (i >= 0 && daily[i].active) { streak++; i--; }

  const last30 = daily.slice(-30);
  const sourceReports = [claude, codex, grok, kiro, omp, pi];
  const last30Usd = sourceReports.reduce((sum, report) => sum + (report?.last30Usd ?? 0), 0);
  const last30Tokens = sourceReports.reduce(
    (sum, report) => sum + (report?.last30Tokens ?? 0),
    0,
  );

  // Top models across window
  const modelMap = new Map<string, CombinedModel>();
  for (const d of daily) {
    for (const m of d.models) {
      if (isKiroSyntheticAggregate(m)) continue;
      const k = `${m.source}:${m.name}`;
      const e = modelMap.get(k);
      if (e) { e.usd += m.usd; e.tokens += m.tokens; }
      else modelMap.set(k, { ...m });
    }
  }
  const topModels = [...modelMap.values()]
    .sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd))
    .slice(0, 6);

  return {
    daily,
    todayUsd: today?.usd ?? 0,
    todayTokens: today?.tokens ?? 0,
    last30Usd: last30Usd || last30.reduce((s, d) => s + d.usd, 0),
    last30Tokens: last30Tokens || last30.reduce((s, d) => s + d.tokens, 0),
    totalUsd,
    totalTokens,
    activeDays: active.length,
    peakUsd: peak?.usd ?? 0,
    peakDate: peak && peak.usd > 0 ? peak.date : null,
    avgActiveUsd: active.length ? totalUsd / active.length : 0,
    streakDays: streak,
    topModels,
  };
}

// --- Weekly Digest window stats ---------------------------------------------

export type DigestWindowStats = {
  usd: number;
  tokens: number;
  bySource: Record<UsageSourceId, { usd: number; tokens: number }>;
  /** Deterministic tie-break: tokens desc, then usd desc, then source name
   * (iteration order below is already alphabetical claude/codex/grok). */
  topSource: UsageSourceId | null;
  /** Deterministic tie-break: tokens desc, then usd desc, then model name,
   * then source — never depends on map/array insertion order. */
  topModel: CombinedModel | null;
};

function compareDigestLabels(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Sum a `combine()` daily array over an inclusive `[startDate, endDate]`
 * range (YYYY-MM-DD strings) restricted to `enabledSources`, for the Weekly
 * Digest notification. Pure function of its inputs — no clock/network
 * access — so it is independently verifiable without live scanners. */
export function digestWindowStats(
  daily: CombinedDay[],
  startDate: string,
  endDate: string,
  enabledSources: ReadonlySet<UsageSourceId>,
): DigestWindowStats {
  const bySource: Record<UsageSourceId, { usd: number; tokens: number }> = {
    claude: { usd: 0, tokens: 0 },
    codex: { usd: 0, tokens: 0 },
    grok: { usd: 0, tokens: 0 },
    omp: { usd: 0, tokens: 0 },
    pi: { usd: 0, tokens: 0 },
    kiro: { usd: 0, tokens: 0 },
  };
  const modelMap = new Map<string, CombinedModel>();
  for (const d of daily) {
    if (d.date < startDate || d.date > endDate) continue;
    for (const source of USAGE_SOURCE_IDS) {
      if (!enabledSources.has(source)) continue;
      const usage = combinedDaySourceUsage(d, source);
      bySource[source].usd += usage.usd;
      bySource[source].tokens += usage.tokens;
    }
    for (const m of d.models) {
      if (!enabledSources.has(m.source)) continue;
      if (m.source === "kiro" && m.name === KIRO_AGGREGATE_MODEL_NAME) continue;
      const key = `${m.source}:${m.name}`;
      const existing = modelMap.get(key);
      if (existing) { existing.usd += m.usd; existing.tokens += m.tokens; }
      else modelMap.set(key, { ...m });
    }
  }

  let topSource: UsageSourceId | null = null;
  for (const s of USAGE_SOURCE_IDS) {
    if (!enabledSources.has(s)) continue;
    const cand = bySource[s];
    if (cand.usd === 0 && cand.tokens === 0) continue;
    if (!topSource) { topSource = s; continue; }
    const best = bySource[topSource];
    if (cand.tokens !== best.tokens) { if (cand.tokens > best.tokens) topSource = s; continue; }
    if (cand.usd !== best.usd && cand.usd > best.usd) topSource = s;
  }

  const topModel = [...modelMap.values()].sort((a, b) =>
    (b.tokens - a.tokens) || (b.usd - a.usd)
      || compareDigestLabels(a.name, b.name) || compareDigestLabels(a.source, b.source),
  )[0] ?? null;

  return {
    usd: USAGE_SOURCE_IDS.reduce((sum, source) => sum + bySource[source].usd, 0),
    tokens: USAGE_SOURCE_IDS.reduce((sum, source) => sum + bySource[source].tokens, 0),
    bySource,
    topSource,
    topModel,
  };
}

// --- Budget & weekly forecast (Phase 2) -------------------------------------

/** `already-over`: week-to-date spend already exceeds the budget.
 * `forecast-over`: still under budget so far, but the linear projection
 * would exceed it by week end. `on-track`: neither. */
export type BudgetStatus = "on-track" | "forecast-over" | "already-over";

export type MonthlyForecast = {
  budgetUsd: number;
  /** Spend from start of the current local calendar week through today. */
  monthToDateUsd: number;
  /** 1-based day of week "as of", inclusive of today (1…7). */
  daysElapsed: number;
  /** Always 7 for a calendar week. */
  daysInMonth: number;
  /** Linear projection: `monthToDateUsd / daysElapsed * daysInMonth`. */
  projectedUsd: number;
  /** `budgetUsd - monthToDateUsd`; negative once already over budget. */
  remainingUsd: number;
  /** `monthToDateUsd / budgetUsd * 100`, uncapped (can exceed 100). */
  usedPct: number;
  /** `projectedUsd / budgetUsd * 100`, uncapped. */
  projectedPct: number;
  status: BudgetStatus;
};

/** Which `CombinedDay` field `monthlyForecast` sums per day.
 * `.total` (the default) preserves the combined-budget behavior that
 * predates this case; every source variant isolates one provider's own daily
 * USD so a per-provider budget never mixes in the other sources' spend. */
export type MonthlyForecastSource = "total" | UsageSourceId;

function monthlyForecastDayUsd(d: CombinedDay, source: MonthlyForecastSource): number {
  return source === "total" ? d.usd : combinedDaySourceUsage(d, source).usd;
}
/** ISO local calendar-week start (Monday 00:00). */
function startOfLocalWeek(now: Date): Date {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const daysSinceMonday = (d.getDay() + 6) % 7;
  d.setDate(d.getDate() - daysSinceMonday);
  return d;
}

function ymdLocal(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** Calendar-day distance using local date increments, independent of DST. */
function localCalendarDayOffset(start: Date, end: Date): number {
  const cursor = new Date(start.getFullYear(), start.getMonth(), start.getDate());
  const endKey = ymdLocal(end);
  let offset = 0;
  while (ymdLocal(cursor) < endKey) {
    cursor.setDate(cursor.getDate() + 1);
    offset += 1;
  }
  return offset;
}

/** Pure week-to-date + linear-projection forecast for budget cards.
 * Filters `daily` to the CURRENT local ISO calendar week only (Mon–Sun, not a
 * rolling 7-day window), through today, then projects a full-week total
 * assuming the same daily average holds for the rest of the week. `now` is
 * injectable for deterministic testing.
 *
 * `budgetUsd` must be a finite, positive number — blank/NaN/zero/negative
 * all return `null` so the caller hides the card entirely (feature off).
 * Non-finite or negative per-day `usd` is ignored. `source` (default
 * `"total"`) selects which field is summed. */
/** Kỳ ngân sách — người dùng chọn trong Settings (macOS parity 2026-08-23). */
export type BudgetPeriod = "week" | "month";
const BUDGET_PERIOD_KEY = "birdnion.budgetPeriod";

export function budgetPeriod(): BudgetPeriod {
  return localStorage.getItem(BUDGET_PERIOD_KEY) === "month" ? "month" : "week";
}

export function setBudgetPeriod(period: BudgetPeriod): void {
  localStorage.setItem(BUDGET_PERIOD_KEY, period);
}

export function monthlyForecast(
  daily: CombinedDay[],
  budgetUsd: number | null | undefined,
  now: Date = new Date(),
  source: MonthlyForecastSource = "total",
  period: BudgetPeriod = budgetPeriod(),
): MonthlyForecast | null {
  if (budgetUsd == null || !Number.isFinite(budgetUsd) || budgetUsd <= 0) return null;

  const isMonth = period === "month";
  const periodStart = isMonth
    ? new Date(now.getFullYear(), now.getMonth(), 1)
    : startOfLocalWeek(now);
  const todayKey = ymdLocal(now);
  const periodStartKey = ymdLocal(periodStart);
  const monthToDateUsd = daily
    .filter((d) => d.date >= periodStartKey && d.date <= todayKey)
    .reduce((sum, d) => {
      const v = monthlyForecastDayUsd(d, source);
      return sum + (Number.isFinite(v) && v > 0 ? v : 0);
    }, 0);

  const daysInMonth = isMonth
    ? new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate()
    : 7;
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const dayOffset = localCalendarDayOffset(periodStart, startOfToday);
  const daysElapsed = Math.min(Math.max(dayOffset + 1, 1), daysInMonth);
  const projectedUsd = (monthToDateUsd / daysElapsed) * daysInMonth;

  const status: BudgetStatus =
    monthToDateUsd > budgetUsd ? "already-over"
      : projectedUsd > budgetUsd ? "forecast-over"
        : "on-track";

  return {
    budgetUsd,
    monthToDateUsd,
    daysElapsed,
    daysInMonth,
    projectedUsd,
    remainingUsd: budgetUsd - monthToDateUsd,
    usedPct: (monthToDateUsd / budgetUsd) * 100,
    projectedPct: (projectedUsd / budgetUsd) * 100,
    status,
  };
}

export function usd(amount: number): string {
  if (amount >= 1000) {
    return "$" + amount.toLocaleString("en-US", { maximumFractionDigits: 0 });
  }
  return "$" + amount.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** USD làm tròn nguyên — dùng cho hàng stats gọn dưới biểu đồ. */
export function usdWhole(amount: number): string {
  return "$" + amount.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

export function tokens(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B tokens`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M tokens`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K tokens`;
  return `${n} tokens`;
}

export function tokensShort(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return `${n}`;
}

// Model-row readout: unpriced models (the cost scanners price non-Claude
// models at $0) show tokens only — "$0.00" reads like real spend data that
// is simply wrong. Mirrors macOS `AllUsageFormat.tokensAndUSD`.
export function tokensAndUsd(tokenCount: number, amount: number): string {
  return amount < 0.005 ? tokensShort(tokenCount) : `${tokensShort(tokenCount)} · ${usd(amount)}`;
}

export function dayLabel(date: string): string {
  const d = new Date(date + "T12:00:00");
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}
