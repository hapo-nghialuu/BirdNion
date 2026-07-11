// Types mirroring src-tauri/src/usage.rs (serde camelCase) plus the
// combined-report math ported from the macOS `CombinedUsageReport.build`
// (Claude + Codex + Grok).

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

export type CombinedModel = {
  name: string;
  usd: number;
  tokens: number;
  source: "claude" | "codex" | "grok";
};

export type CombinedDay = {
  date: string;
  claudeUsd: number;
  claudeTokens: number;
  codexUsd: number;
  codexTokens: number;
  grokUsd: number;
  grokTokens: number;
  usd: number;
  tokens: number;
  active: boolean;
  models: CombinedModel[];
};

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

/** Merge scanners' daily arrays by calendar-day string (Claude + Codex + Grok). */
export function combine(
  claude: UsageReport | null,
  codex: UsageReport | null,
  grok: UsageReport | null = null,
): Combined {
  const byDate = new Map<string, CombinedDay>();
  const seed = (r: UsageReport | null, source: "claude" | "codex" | "grok") => {
    for (const d of r?.daily ?? []) {
      let day = byDate.get(d.date);
      if (!day) {
        day = {
          date: d.date,
          claudeUsd: 0, claudeTokens: 0,
          codexUsd: 0, codexTokens: 0,
          grokUsd: 0, grokTokens: 0,
          usd: 0, tokens: 0, active: false, models: [],
        };
        byDate.set(d.date, day);
      }
      if (source === "claude") { day.claudeUsd += d.usd; day.claudeTokens += d.tokens; }
      else if (source === "codex") { day.codexUsd += d.usd; day.codexTokens += d.tokens; }
      else { day.grokUsd += d.usd; day.grokTokens += d.tokens; }
      day.usd = day.claudeUsd + day.codexUsd + day.grokUsd;
      day.tokens = day.claudeTokens + day.codexTokens + day.grokTokens;
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
  const daily = [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
  for (const d of daily) d.models.sort((a, b) => (b.usd - a.usd) || (b.tokens - a.tokens));

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
  const last30Usd = (claude?.last30Usd ?? 0) + (codex?.last30Usd ?? 0) + (grok?.last30Usd ?? 0);
  const last30Tokens = (claude?.last30Tokens ?? 0) + (codex?.last30Tokens ?? 0) + (grok?.last30Tokens ?? 0);

  // Top models across window
  const modelMap = new Map<string, CombinedModel>();
  for (const d of daily) {
    for (const m of d.models) {
      const k = `${m.source}:${m.name}`;
      const e = modelMap.get(k);
      if (e) { e.usd += m.usd; e.tokens += m.tokens; }
      else modelMap.set(k, { ...m });
    }
  }
  const topModels = [...modelMap.values()]
    .sort((a, b) => (b.usd - a.usd) || (b.tokens - a.tokens))
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

export function usd(amount: number): string {
  if (amount >= 1000) {
    return "$" + amount.toLocaleString("en-US", { maximumFractionDigits: 0 });
  }
  return "$" + amount.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
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

export function dayLabel(date: string): string {
  const d = new Date(date + "T12:00:00");
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}
