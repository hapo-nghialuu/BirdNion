/** Per-provider fetch lanes for the Linux popover (task-09): the JS mirror
 * of macOS `ProviderLane` (task-02). One lane owns a provider id across every
 * fetch path — initial fanout, manual retry, tick — so a provider is never
 * fetched twice concurrently, a forced kick queues exactly one follow-up
 * behind the in-flight fetch, and consecutive failures stretch that
 * provider's own due interval with capped backoff (x1/x2/x4/x8). */

export type LaneInteraction = "background" | "manual";

export type LaneRun = () => Promise<void>;

/** Failure-streak backoff (macOS `adaptiveBackoffMultiplier` parity): the
 * first failure keeps the configured interval, then x2/x4, capped at x8. */
export function adaptiveBackoffMultiplier(consecutiveFailures: number): number {
  const failures = Math.max(0, Math.trunc(consecutiveFailures));
  if (failures <= 1) return 1;
  if (failures === 2) return 2;
  if (failures === 3) return 4;
  return 8;
}

export class ProviderLane {
  readonly id: string;
  /** ms timestamp of the last attempted fetch (success or failure). */
  lastFetched: number | undefined;
  /** Consecutive background-fetch failures — drives `intervalMs` backoff. */
  failureStreak = 0;
  /** The lane's live fetch chain; a queued force follow-up extends it, so a
   * lane stays "in flight" until its last queued run settles. */
  inFlight: Promise<void> | null = null;
  /** Which kick kind owns the current run — manual kicks reset the streak. */
  private lastInteraction: LaneInteraction = "background";
  private forceQueued = false;

  constructor(id: string) {
    this.id = id;
  }

  /** Join or start this lane's fetch. A non-force kick during in-flight
   * joins the owner's promise — the joiner's `run` is dropped, the owner
   * still applies the result. A force kick during in-flight queues exactly
   * one follow-up `run` behind it and resolves after that follow-up
   * settles; extra force kicks while one is queued join the same chain. */
  kick(force: boolean, interaction: LaneInteraction, run: LaneRun): Promise<void> {
    if (this.inFlight) {
      if (!force || this.forceQueued) return this.inFlight;
      this.forceQueued = true;
      const extended = this.inFlight
        .catch(() => {})
        .then(async () => {
          this.forceQueued = false;
          this.lastInteraction = interaction;
          await run();
        });
      this.adopt(extended);
      return extended;
    }
    this.lastInteraction = interaction;
    const started = run();
    this.adopt(started);
    return started;
  }

  /** Keep `inFlight` pointing at the live tail only while it is unsettled —
   * a settled (especially rejected) promise left in place would make every
   * later kick join dead work instead of starting a fetch. */
  private adopt(p: Promise<void>): void {
    this.inFlight = p;
    const clear = () => {
      if (this.inFlight === p) this.inFlight = null;
    };
    void p.then(clear, clear);
  }

  /** Effective interval with failure backoff (x1/x2/x4/x8 cap). A non-positive
   * base (manual mode) is never stretched. */
  intervalMs(baseMs: number): number {
    if (baseMs <= 0) return baseMs;
    return baseMs * adaptiveBackoffMultiplier(this.failureStreak);
  }

  /** Due check for the tick loop: never fetched ⇒ due; otherwise due once
   * the provider's own backoff-adjusted interval has elapsed. */
  isDue(now: number, baseIntervalMs: number): boolean {
    if (this.lastFetched === undefined) return true;
    return now - this.lastFetched >= this.intervalMs(baseIntervalMs);
  }

  /** Record a settled fetch attempt. Every attempt stamps `lastFetched`
   * (even a result that omitted the status); manual kicks start a fresh
   * streak instead of inheriting automatic backoff; success clears it. */
  recordOutcome(succeeded: boolean, now: number): void {
    this.lastFetched = now;
    if (succeeded) {
      this.failureStreak = 0;
      return;
    }
    this.failureStreak = (this.lastInteraction === "manual" ? 0 : this.failureStreak) + 1;
  }

  /** Drop scheduling state (last-fetch timestamp + failure streak) — used
   * when a provider leaves the enabled set or its identity is cleared, so a
   * re-enable/refetch is due immediately instead of inheriting old backoff. */
  resetSchedule(): void {
    this.lastFetched = undefined;
    this.failureStreak = 0;
  }
}

/** Lane registry keyed by provider id — replaces the bare `lastFetched` /
 * `inFlightProviderIds` / `adaptiveFailureStreaks` maps. */
export class ProviderLanes {
  private readonly lanes = new Map<string, ProviderLane>();

  lane(id: string): ProviderLane {
    let lane = this.lanes.get(id);
    if (!lane) {
      lane = new ProviderLane(id);
      this.lanes.set(id, lane);
    }
    return lane;
  }

  isInFlight(id: string): boolean {
    return this.lanes.get(id)?.inFlight != null;
  }

  inFlightIds(): ReadonlySet<string> {
    const ids = new Set<string>();
    for (const [id, lane] of this.lanes) {
      if (lane.inFlight) ids.add(id);
    }
    return ids;
  }

  ids(): string[] {
    return [...this.lanes.keys()];
  }
}

/** Enrichment-only fields a `birdnion-provider-extras` payload may carry —
 * mirrors the Rust `merge_status_extras` field set in providers/mod.rs.
 * Everything else on the payload (windows, error, account/source labels,
 * timestamps) is core-owned and must never be applied here. */
export type ProviderExtrasFields = {
  version?: string;
  serviceStatus?: string;
  serviceStatusLevel?: string;
  resetCreditsAvailable?: number;
  signedInEmail?: string;
  codeReviewRemainingPercent?: number;
  creditsPurchaseUrl?: string;
  creditsHistoryCount?: number;
  creditsRemaining?: number;
  kiroContextPercent?: number;
  creditsUnlimited?: boolean;
};

/** Fill enrichment gaps on an already-rendered core status. Field-scoped:
 * extras never touch windows/error/labels — same gap-fill rule as the Rust
 * merge so a stale tail can never clobber fresher core data. */
export function mergeStatusExtras<T extends ProviderExtrasFields>(
  core: T,
  extras: ProviderExtrasFields,
): T {
  core.version ??= extras.version;
  core.serviceStatus ??= extras.serviceStatus;
  core.serviceStatusLevel ??= extras.serviceStatusLevel;
  core.resetCreditsAvailable ??= extras.resetCreditsAvailable;
  core.signedInEmail ??= extras.signedInEmail;
  core.codeReviewRemainingPercent ??= extras.codeReviewRemainingPercent;
  core.creditsPurchaseUrl ??= extras.creditsPurchaseUrl;
  core.creditsHistoryCount ??= extras.creditsHistoryCount;
  core.creditsRemaining ??= extras.creditsRemaining;
  core.kiroContextPercent ??= extras.kiroContextPercent;
  core.creditsUnlimited = core.creditsUnlimited === true || extras.creditsUnlimited === true;
  return core;
}

/** TTL wrapper for a slow async read (task-09: `get_settings` inside the
 * tick loop — max one IPC per 30s of ticks). The settled value is cached
 * regardless of content; the caller decides what an empty result means, the
 * TTL only bounds call rate. */
export function createTtlCache<T>(
  ttlMs: number,
  fetcher: () => Promise<T>,
  now: () => number = () => Date.now(),
): () => Promise<T> {
  let cachedAt = Number.NEGATIVE_INFINITY;
  let cached: T;
  return async () => {
    const t = now();
    if (t - cachedAt >= ttlMs) {
      cached = await fetcher();
      cachedAt = t;
    }
    return cached;
  };
}
