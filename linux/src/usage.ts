// Types mirroring src-tauri/src/usage.rs (serde camelCase) plus the
// combined-report math ported from the macOS `CombinedUsageReport.build`.

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
};

export type CombinedModel = { name: string; usd: number; tokens: number; source: "claude" | "codex" };

export type CombinedDay = {
  date: string;
  claudeUsd: number;
  claudeTokens: number;
  codexUsd: number;
  codexTokens: number;
  usd: number;
  tokens: number;
  active: boolean;
  /** Per-model split for this day (both sources, cost-sorted). Feeds the
   * day-detail breakdown so "Claude" isn't a single opaque line. Approximate:
   * each scanner only records the top 5 models per day. */
  models: CombinedModel[];
};

export type Combined = {
  daily: CombinedDay[]; // 90 days, oldest → newest
  todayUsd: number;
  todayTokens: number;
  last30Usd: number;
  last30Tokens: number;
  totalUsd: number; // 90-day window
  totalTokens: number;
  activeDays: number;
  peakUsd: number;
  peakDate: string | null;
  avgActiveUsd: number;
  streakDays: number;
  topModels: CombinedModel[];
};

/** Merge both scanners' daily arrays by calendar-day string. Both arrays are
 * already contiguous 90-day windows ending today (same local calendar), so a
 * date-keyed map lines them up even when one source is missing. */
export function combine(claude: UsageReport | null, codex: UsageReport | null): Combined {
  const byDate = new Map<string, CombinedDay>();
  const dates: string[] = [];
  const seed = (r: UsageReport | null, source: "claude" | "codex") => {
    for (const d of r?.daily ?? []) {
      let day = byDate.get(d.date);
      if (!day) {
        day = {
          date: d.date,
          claudeUsd: 0, claudeTokens: 0, codexUsd: 0, codexTokens: 0,
          usd: 0, tokens: 0, active: false, models: [],
        };
        byDate.set(d.date, day);
        dates.push(d.date);
      }
      if (source === "claude") { day.claudeUsd += d.usd; day.claudeTokens += d.tokens; }
      else { day.codexUsd += d.usd; day.codexTokens += d.tokens; }
      day.usd = day.claudeUsd + day.codexUsd;
      day.tokens = day.claudeTokens + day.codexTokens;
      day.active = day.usd > 0 || day.tokens > 0;
      // Fold this source's per-day model split into the day, merged by name.
      for (const m of d.models) {
        const existing = day.models.find((x) => x.source === source && x.name === m.name);
        if (existing) { existing.usd += m.usd; existing.tokens += m.tokens; }
        else { day.models.push({ name: m.name, usd: m.usd, tokens: m.tokens, source }); }
      }
    }
  };
  seed(claude, "claude");
  seed(codex, "codex");
  const daily = [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
  // Cost-sort each day's models so the detail lists the biggest spend first.
  for (const d of daily) d.models.sort((a, b) => (b.usd - a.usd) || (b.tokens - a.tokens));

  const today = daily[daily.length - 1];
  const totalUsd = daily.reduce((s, d) => s + d.usd, 0);
  const totalTokens = daily.reduce((s, d) => s + d.tokens, 0);
  const active = daily.filter((d) => d.active);
  const peak = daily.reduce<CombinedDay | null>(
    (best, d) => (d.usd > (best?.usd ?? 0) ? d : best), null);

  // Streak counted back from the most recent activity; an inactive today
  // doesn't break it (the day isn't over yet).
  let streak = 0;
  let i = daily.length - 1;
  if (i >= 0 && !daily[i].active) i--;
  while (i >= 0 && daily[i].active) { streak++; i--; }

  // Merge per-day model splits per source (approximate: each day only
  // records its top 5 models), then interleave by cost.
  const sumModels = (r: UsageReport | null, source: "claude" | "codex"): CombinedModel[] => {
    const acc = new Map<string, CombinedModel>();
    for (const d of r?.daily ?? []) {
      for (const m of d.models) {
        const cur = acc.get(m.name) ?? { name: m.name, usd: 0, tokens: 0, source };
        cur.usd += m.usd;
        cur.tokens += m.tokens;
        acc.set(m.name, cur);
      }
    }
    return [...acc.values()];
  };
  const topModels = [...sumModels(claude, "claude"), ...sumModels(codex, "codex")]
    .filter((m) => m.usd > 0 || m.tokens > 0)
    .sort((a, b) => (b.usd - a.usd) || (b.tokens - a.tokens))
    .slice(0, 6);

  return {
    daily,
    todayUsd: today?.usd ?? 0,
    todayTokens: today?.tokens ?? 0,
    last30Usd: (claude?.last30Usd ?? 0) + (codex?.last30Usd ?? 0),
    last30Tokens: (claude?.last30Tokens ?? 0) + (codex?.last30Tokens ?? 0),
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

// --- Formatting (same conventions as the macOS AllUsageFormat) -----------

export const usd = (n: number) =>
  n >= 1000 ? `$${Math.round(n).toLocaleString("en-US")}` : `$${n.toFixed(2)}`;

export const tokens = (n: number) =>
  n >= 1e9 ? `${(n / 1e9).toFixed(1)}B tokens`
  : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M tokens`
  : n >= 1e3 ? `${(n / 1e3).toFixed(1)}K tokens`
  : `${n} tokens`;

export const tokensShort = (n: number) =>
  n >= 1e9 ? `${(n / 1e9).toFixed(1)}B`
  : n >= 1e7 ? `${Math.round(n / 1e6)}M`
  : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M`
  : n >= 1e3 ? `${Math.round(n / 1e3)}K`
  : `${n}`;

/** "2026-07-04" → "4/7" (day/month, vi style). */
export const dayLabel = (date: string) => {
  const [, m, d] = date.split("-");
  return `${Number(d)}/${Number(m)}`;
};
