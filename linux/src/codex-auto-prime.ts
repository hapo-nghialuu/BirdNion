import type { ProviderStatus, QuotaWindow } from "./provider-tab";

export const CODEX_AUTO_PRIME_ENABLED_KEY = "birdnion.codexAutoPrimeEnabled";
export const CODEX_AUTO_PRIME_MINUTES_KEY = "birdnion.codexAutoPrimeMinutes";
export const CODEX_AUTO_PRIME_LAST_ATTEMPT_KEY = "birdnion.codexAutoPrimeLastAttempt";
export const DEFAULT_CODEX_AUTO_PRIME_MINUTES = 8 * 60 + 55;

export type CodexAutoPrimePreferences = {
  enabled: boolean;
  scheduledMinutes: number;
  lastAttemptMs: number;
};

type StorageLike = Pick<Storage, "getItem" | "setItem">;

function finiteNumber(raw: string | null, fallback: number): number {
  if (raw === null || raw.trim() === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

export function clampScheduledMinutes(value: number): number {
  return Math.max(0, Math.min(1439, Math.round(value)));
}

export function loadCodexAutoPrimePreferences(
  storage: StorageLike = localStorage,
): CodexAutoPrimePreferences {
  return {
    enabled: storage.getItem(CODEX_AUTO_PRIME_ENABLED_KEY) === "true",
    scheduledMinutes: clampScheduledMinutes(finiteNumber(
      storage.getItem(CODEX_AUTO_PRIME_MINUTES_KEY),
      DEFAULT_CODEX_AUTO_PRIME_MINUTES,
    )),
    lastAttemptMs: Math.max(0, finiteNumber(
      storage.getItem(CODEX_AUTO_PRIME_LAST_ATTEMPT_KEY),
      0,
    )),
  };
}

export function saveCodexAutoPrimePreferences(
  preferences: Pick<CodexAutoPrimePreferences, "enabled" | "scheduledMinutes">,
  storage: StorageLike = localStorage,
): void {
  storage.setItem(CODEX_AUTO_PRIME_ENABLED_KEY, String(preferences.enabled));
  storage.setItem(
    CODEX_AUTO_PRIME_MINUTES_KEY,
    String(clampScheduledMinutes(preferences.scheduledMinutes)),
  );
}

function sameLocalDay(leftMs: number, right: Date): boolean {
  if (leftMs <= 0) return false;
  const left = new Date(leftMs);
  return Number.isFinite(left.getTime())
    && left.getFullYear() === right.getFullYear()
    && left.getMonth() === right.getMonth()
    && left.getDate() === right.getDate();
}

export function shouldPrimeCodex(input: {
  now: Date;
  enabled: boolean;
  scheduledMinutes: number;
  lastAttemptMs: number;
  windowUsedPct?: number;
}): boolean {
  if (!input.enabled) return false;
  if (input.windowUsedPct !== undefined && input.windowUsedPct > 0) return false;
  const nowMinutes = input.now.getHours() * 60 + input.now.getMinutes();
  if (nowMinutes < clampScheduledMinutes(input.scheduledMinutes)) return false;
  return !sameLocalDay(input.lastAttemptMs, input.now);
}

function isFiveHourWindow(window: QuotaWindow): boolean {
  if (window.isInactive || window.isSupplementary) return false;
  if (window.windowSeconds !== undefined
      && Math.abs(window.windowSeconds - 5 * 60 * 60) <= 5 * 60) return true;
  const label = window.label.toLocaleLowerCase();
  return /(^|\s)5\s*(h|giờ|hour)/u.test(label);
}

export function codexFiveHourUsedPct(status: ProviderStatus): number | undefined {
  return status.windows.find(isFiveHourWindow)?.usedPct;
}

let primeInFlight = false;

export async function maybePrimeCodex(input: {
  status: ProviderStatus | undefined;
  invokePrime: () => Promise<boolean>;
  onSuccess?: (now: Date) => void | Promise<void>;
  now?: Date;
  storage?: StorageLike;
}): Promise<"skipped" | "attempted" | "succeeded"> {
  if (!input.status || input.status.id !== "codex" || primeInFlight) return "skipped";
  const storage = input.storage ?? localStorage;
  const preferences = loadCodexAutoPrimePreferences(storage);
  const now = input.now ?? new Date();
  if (!shouldPrimeCodex({
    now,
    enabled: preferences.enabled,
    scheduledMinutes: preferences.scheduledMinutes,
    lastAttemptMs: preferences.lastAttemptMs,
    windowUsedPct: codexFiveHourUsedPct(input.status),
  })) return "skipped";

  // Stamp before awaiting the process so overlapping refresh/focus ticks cannot
  // launch duplicate Codex requests. A failed attempt is intentionally not
  // retried until tomorrow.
  storage.setItem(CODEX_AUTO_PRIME_LAST_ATTEMPT_KEY, String(now.getTime()));
  primeInFlight = true;
  try {
    const succeeded = await input.invokePrime();
    if (!succeeded) return "attempted";
    await input.onSuccess?.(now);
    return "succeeded";
  } catch {
    return "attempted";
  } finally {
    primeInFlight = false;
  }
}
