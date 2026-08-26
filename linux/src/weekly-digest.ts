// Weekly Digest — one OS notification summarizing the trailing rolling
// 7-day window (today + 6 prior days, NOT an ISO/calendar week). Default OFF
// because the notification body can reveal spend/token totals outside the
// popover. Rides the existing main.ts tick loop (`checkWeeklyDigest`) instead
// of a new timer, and reuses `combine`/`monthlyForecast`/formatters from
// `./usage`, the `notify` Tauri command, and the `${source}_usage_report`
// commands already used for the All tab.

import { invoke } from "@tauri-apps/api/core";
import {
  combine, monthlyForecast, scanConfidence, usd, tokens as tokensLabel,
  digestWindowStats, USAGE_SOURCE_IDS, type UsageReport, type UsageSourceId, type DigestWindowStats,
  type MonthlyForecast, type Combined,
} from "./usage";
import { getMonthlyBudgetUsd, getProviderBudgetUsd } from "./settings-about";
import { t } from "./i18n";

const SOURCES: readonly UsageSourceId[] = USAGE_SOURCE_IDS;
const SOURCE_NAMES: Record<UsageSourceId, string> = {
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
  kiro: "Kiro",
  omp: "Oh My Pi",
  pi: "Pi",
};

const ENABLED_KEY = "birdnion.weeklyDigestEnabled";
const LAST_EVALUATED_KEY = "birdnion.weeklyDigestLastEvaluatedAt";
const LAST_SENT_KEY = "birdnion.weeklyDigestLastSentAt";
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
/** Caps any dynamic label (model name) interpolated into the OS notification
 * body — defends against a corrupt/oversized scanner value, not a security
 * boundary (model names never carry email/account/API-key data). */
const LABEL_MAX_LEN = 60;

export function isWeeklyDigestEnabled(): boolean {
  return localStorage.getItem(ENABLED_KEY) === "true";
}

/** Turning the digest ON clears the evaluation mark so the very next tick
 * evaluates immediately instead of waiting up to 7 days for the first run. */
export function setWeeklyDigestEnabled(enabled: boolean): void {
  localStorage.setItem(ENABLED_KEY, String(enabled));
  if (enabled) localStorage.removeItem(LAST_EVALUATED_KEY);
}

function getLastEvaluatedAt(): number | null {
  const raw = localStorage.getItem(LAST_EVALUATED_KEY);
  const n = raw == null ? NaN : Number(raw);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function markEvaluated(): void {
  localStorage.setItem(LAST_EVALUATED_KEY, String(Date.now()));
}

function markSent(): void {
  localStorage.setItem(LAST_SENT_KEY, String(Date.now()));
}

/** Strip control/newline characters and cap length. */
function sanitizeLabel(raw: string): string {
  const cleaned = raw.replace(/[\p{Cc}]+/gu, " ").trim();
  return cleaned.length > LABEL_MAX_LEN ? `${cleaned.slice(0, LABEL_MAX_LEN)}…` : cleaned;
}

function dateKey(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function addDays(d: Date, n: number): Date {
  const copy = new Date(d);
  copy.setDate(copy.getDate() + n);
  return copy;
}

async function readEnabledSources(): Promise<Set<UsageSourceId>> {
  const sourceIds: string[] = await invoke<string[]>("enabled_local_usage_source_ids")
    .catch((): string[] => []);
  return new Set(SOURCES.filter((source) => sourceIds.includes(source)));
}

async function fetchEnabledReports(): Promise<{
  enabled: Set<UsageSourceId>;
  reports: Record<UsageSourceId, UsageReport | null>;
}> {
  // Use the backend's canonical provider-enabled OR installed-agent
  // predicate. This is the same set that gates All/Insights scanner commands,
  // so disabling a provider cannot hide cost from a detected local agent.
  const enabled = await readEnabledSources();
  const reports: Record<UsageSourceId, UsageReport | null> =
    { claude: null, codex: null, grok: null, omp: null, pi: null, kiro: null };
  for (const s of enabled) {
    reports[s] = await invoke<UsageReport | null>(`${s}_usage_report`).catch(() => null);
  }
  return { enabled, reports };
}

function budgetStatusLabel(status: MonthlyForecast["status"]): string {
  if (status === "already-over") return t("weeklyDigestBudgetOver");
  if (status === "forecast-over") return t("weeklyDigestBudgetForecast");
  return t("weeklyDigestBudgetOnTrack");
}

/** Configured providers forecast-over or already-over their OWN budget this
 * cycle — never a source whose confidence is `"unavailable"` (trust rule:
 * an implicit zero must not be reported as risk), and never `"on-track"`
 * (the digest only calls out risk, keeping the notification concise). */
function providerBudgetRiskLines(
  combined: Combined,
  reports: Record<UsageSourceId, UsageReport | null>,
  budgets: Record<UsageSourceId, number | null>,
  now: Date,
): string[] {
  const lines: string[] = [];
  for (const s of SOURCES) {
    const budget = budgets[s];
    if (budget == null) continue;
    if (scanConfidence(reports[s]) === "unavailable") continue;
    const forecast = monthlyForecast(combined.daily, budget, now, s);
    if (!forecast || forecast.status === "on-track") continue;
    const isAlreadyOver = forecast.status === "already-over";
    const key = isAlreadyOver ? "weeklyDigestProviderBudgetOver" : "weeklyDigestProviderBudgetForecast";
    lines.push(t(key, {
      source: SOURCE_NAMES[s],
      usd: usd(isAlreadyOver ? forecast.monthToDateUsd : forecast.projectedUsd),
      budget: usd(forecast.budgetUsd),
    }));
  }
  return lines;
}

function buildBody(
  current: DigestWindowStats,
  prior: DigestWindowStats,
  forecast: MonthlyForecast | null,
  nonLive: UsageSourceId[],
  providerRiskLines: string[],
): string {
  const lines: string[] = [
    t("weeklyDigestSummary", { usd: usd(current.usd), tokens: tokensLabel(current.tokens) }),
  ];
  if (prior.usd > 0) {
    const pct = Math.round(((current.usd - prior.usd) / prior.usd) * 100);
    lines.push(t("weeklyDigestChange", { sign: pct >= 0 ? "+" : "", pct }));
  }
  if (current.topSource) {
    lines.push(t("weeklyDigestTopSource", { source: SOURCE_NAMES[current.topSource] }));
  }
  if (current.topModel) {
    lines.push(t("weeklyDigestTopModel", { model: sanitizeLabel(current.topModel.name) }));
  }
  if (forecast) {
    lines.push(t("weeklyDigestForecast", { usd: usd(forecast.projectedUsd) }));
    lines.push(budgetStatusLabel(forecast.status));
  }
  if (nonLive.length > 0) {
    const names = nonLive.map((s) => SOURCE_NAMES[s]).join(", ");
    lines.push(t("weeklyDigestCaveat", { sources: names }));
  }
  lines.push(...providerRiskLines);
  return lines.join("\n");
}

async function evaluateAndMaybeNotify(): Promise<void> {
  try {
    const { enabled, reports } = await fetchEnabledReports();
    if (enabled.size === 0) return; // nothing to report — still marks evaluated below

    // Scans can outlive a settings change. Revalidate at the final async
    // boundary, then remove every report that is no longer canonically
    // authorized before any digest total, model, or forecast is derived.
    const currentEnabled = await readEnabledSources();
    if (!isWeeklyDigestEnabled()) return;
    for (const source of SOURCES) {
      if (currentEnabled.has(source)) continue;
      enabled.delete(source);
      reports[source] = null;
    }
    if (enabled.size === 0) return;

    const combined = combine(
      reports.claude,
      reports.codex,
      reports.grok,
      reports.omp,
      reports.pi,
      reports.kiro,
    );
    const now = new Date();
    const todayKey = dateKey(now);
    const currentStart = dateKey(addDays(now, -6));
    const priorEnd = dateKey(addDays(now, -7));
    const priorStart = dateKey(addDays(now, -13));

    const current = digestWindowStats(combined.daily, currentStart, todayKey, enabled);
    const prior = digestWindowStats(combined.daily, priorStart, priorEnd, enabled);

    const nonLive = [...enabled].filter((s) => scanConfidence(reports[s]) !== "live");
    const anyLive = nonLive.length < enabled.size;
    if (!anyLive || (current.usd <= 0 && current.tokens <= 0)) return; // suppress, still evaluated

    const forecast = monthlyForecast(combined.daily, getMonthlyBudgetUsd(), now);
    const providerBudgets: Record<UsageSourceId, number | null> = {
      claude: getProviderBudgetUsd("claude"),
      codex: getProviderBudgetUsd("codex"),
      grok: getProviderBudgetUsd("grok"),
      omp: getProviderBudgetUsd("omp"),
      pi: getProviderBudgetUsd("pi"),
      kiro: getProviderBudgetUsd("kiro"),
    };
    const providerRiskLines = providerBudgetRiskLines(combined, reports, providerBudgets, now);
    const body = buildBody(current, prior, forecast, nonLive, providerRiskLines);
    await invoke("notify", { title: t("weeklyDigestTitle"), body });
    markSent();
  } catch {
    // Notify/report failures are swallowed — `lastSentAt` stays untouched,
    // `lastEvaluatedAt` still advances in `finally` so this cycle doesn't spin.
  } finally {
    markEvaluated();
  }
}

let evaluationInFlight = false;

/** Call from the existing tick loop every cycle — cheap no-op unless the
 * feature is enabled AND the rolling 7-day cadence (since `lastEvaluatedAt`)
 * has elapsed. Guards against overlap if a slow evaluation is still running. */
export async function checkWeeklyDigest(): Promise<void> {
  if (evaluationInFlight || !isWeeklyDigestEnabled()) return;
  const last = getLastEvaluatedAt();
  if (last != null && Date.now() - last < SEVEN_DAYS_MS) return;
  evaluationInFlight = true;
  try {
    await evaluateAndMaybeNotify();
  } finally {
    evaluationInFlight = false;
  }
}
