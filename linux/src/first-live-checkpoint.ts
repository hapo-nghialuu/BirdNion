export type FirstLiveCheckpoint = {
  attemptId: string;
  providerId: string;
  source: string;
  setupSavedAtMs: number;
  probeStartedAtMs: number;
  freshResultReceivedAtMs: number;
  liveRenderedAtMs: number;
  appVersion: string;
  platform: "macos" | "linux";
};

export type FirstLiveAttempt = Omit<
  FirstLiveCheckpoint,
  "freshResultReceivedAtMs" | "liveRenderedAtMs"
>;

export type FirstLiveTestState = "idle" | "testing" | "live" | "failed";
export type FirstLivePhase = FirstLiveTestState | "needsSource" | "readyToTest";
export type FirstLivePersistenceResult = {
  state: "live" | "failed";
  feedbackKey?: "guidedSetupReceiptSaveFailed";
};

type CheckpointStorage = Pick<Storage, "getItem" | "setItem">;
type StoredCheckpoints = {
  checkpoints: Record<string, FirstLiveCheckpoint>;
  writable: boolean;
};

export const FIRST_LIVE_CHECKPOINTS_KEY = "birdnion.firstLiveCheckpoints.v1";
const PROVIDER_IDS = new Set(["claude", "codex", "grok"]);
const ALLOWED_SOURCES_BY_PROVIDER: Readonly<Record<string, ReadonlySet<string>>> = {
  claude: new Set(["Claude Code", "Claude CLI", "Claude Code / CLI"]),
  codex: new Set(["Codex login", "Codex CLI", "Codex login / CLI"]),
  grok: new Set(["Grok login", "Grok sessions", "Grok login / sessions"]),
};
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONTROL_PATTERN = /[\u0000-\u001f\u007f]/;
const APP_VERSION_PATTERN = /^[0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9][A-Za-z0-9.-]{0,31})?$/;
const MAX_FUTURE_SKEW_MS = 5 * 60 * 1_000;
const MAX_STORED_CHARACTERS = 64 * 1024;

/**
 * Mount barrier for configuration-identity listeners. The caller must await
 * this before exposing Guided Setup controls; otherwise an account mutation
 * can occur while registration is still pending and leave an old probe's
 * generation valid.
 */
export async function registerFirstLiveInvalidationBarrier<Cleanup>(
  register: (handler: () => void) => Promise<Cleanup>,
  handler: () => void,
): Promise<Cleanup> {
  return await register(handler);
}

export function canAcknowledgeVisiblePaint(
  documentVisible: boolean,
  nativeVisible: boolean,
  nativeMinimized: boolean,
  nativeFocused: boolean,
): boolean {
  return documentVisible && nativeVisible && !nativeMinimized && nativeFocused;
}

/** Cached/background quota is deliberately absent: only this attempt's
 * explicit `live` result may move Guided Setup into the verified state. */
export function firstLivePhase(
  testState: FirstLiveTestState,
  statusHasError: boolean,
  detectionReady: boolean,
): FirstLivePhase {
  if (testState === "testing") return "testing";
  if (statusHasError) return "failed";
  if (testState === "failed" || testState === "live") return testState;
  return detectionReady ? "readyToTest" : "needsSource";
}

export function shouldApplyFirstLiveCompletion(
  providerId: string,
  generation: number,
  activeGeneration: number | undefined,
  selectedProviderId: string,
  isProviderEnabled: boolean,
): boolean {
  return isProviderEnabled
    && activeGeneration === generation
    && selectedProviderId === providerId;
}

/** Invalidating a provider clears settled UI evidence. A running probe stays
 * registered only so it cannot be duplicated before its stale promise settles. */
export function shouldRetainFirstLiveTestOnInvalidation(
  state: FirstLiveTestState | undefined,
): boolean {
  return state === "testing";
}

/** A successful probe is not a durable First Live success until its receipt
 * was acknowledged by storage. This keeps Linux aligned with macOS when
 * localStorage is denied, full, or structurally unreadable. */
export function firstLivePersistenceResult(saved: boolean): FirstLivePersistenceResult {
  return saved
    ? { state: "live" }
    : { state: "failed", feedbackKey: "guidedSetupReceiptSaveFailed" };
}

export function beginFirstLiveAttempt(options: {
  providerId: string;
  detectedSource: string;
  setupSavedAtMs?: number;
  probeStartedAtMs?: number;
  attemptId?: string;
  appVersion: string;
  platform?: "macos" | "linux";
}): FirstLiveAttempt | null {
  if (!PROVIDER_IDS.has(options.providerId)) return null;
  const appVersion = safeVersion(options.appVersion);
  if (appVersion == null) return null;
  const setupSavedAtMs = safeTimestamp(options.setupSavedAtMs ?? Date.now());
  const probeStartedAtMs = Math.max(
    setupSavedAtMs,
    safeTimestamp(options.probeStartedAtMs ?? Date.now()),
  );
  return {
    attemptId: (options.attemptId ?? crypto.randomUUID()).toLowerCase(),
    providerId: options.providerId,
    source: safeSource(options.providerId, options.detectedSource),
    setupSavedAtMs,
    probeStartedAtMs,
    appVersion,
    platform: options.platform ?? "linux",
  };
}

export function completeFirstLiveAttempt(
  attempt: FirstLiveAttempt,
  freshResultReceivedAtMs: number = Date.now(),
  liveRenderedAtMs: number = Date.now(),
): FirstLiveCheckpoint {
  const freshMs = Math.max(attempt.probeStartedAtMs, safeTimestamp(freshResultReceivedAtMs));
  const renderedMs = Math.max(freshMs, safeTimestamp(liveRenderedAtMs));
  return {
    ...attempt,
    freshResultReceivedAtMs: freshMs,
    liveRenderedAtMs: renderedMs,
  };
}

export function checkpointDurationMs(checkpoint: FirstLiveCheckpoint): number {
  return Math.max(0, checkpoint.liveRenderedAtMs - checkpoint.probeStartedAtMs);
}

export function loadFirstLiveCheckpoints(
  storage: CheckpointStorage = localStorage,
): Record<string, FirstLiveCheckpoint> {
  return readFirstLiveCheckpoints(storage).checkpoints;
}

function readFirstLiveCheckpoints(storage: CheckpointStorage): StoredCheckpoints {
  try {
    const encoded = storage.getItem(FIRST_LIVE_CHECKPOINTS_KEY);
    if (encoded == null) return { checkpoints: {}, writable: true };
    if (encoded.length > MAX_STORED_CHARACTERS) {
      return { checkpoints: {}, writable: false };
    }
    const decoded: unknown = JSON.parse(encoded);
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
      return { checkpoints: {}, writable: false };
    }
    const entries = Object.entries(decoded);
    if (entries.length > PROVIDER_IDS.size
      || entries.some(([providerId]) => !PROVIDER_IDS.has(providerId))) {
      return { checkpoints: {}, writable: false };
    }
    const result: Record<string, FirstLiveCheckpoint> = {};
    for (const [providerId, entry] of entries) {
      const checkpoint = normalizeCheckpoint(entry);
      if (checkpoint?.providerId === providerId) {
        result[providerId] = checkpoint;
      }
    }
    return { checkpoints: result, writable: true };
  } catch {
    return { checkpoints: {}, writable: false };
  }
}

export function saveFirstLiveCheckpoint(
  checkpoint: FirstLiveCheckpoint,
  storage: CheckpointStorage = localStorage,
): boolean {
  const normalized = normalizeCheckpoint(checkpoint);
  const nowMs = Date.now();
  if (!normalized || normalized.liveRenderedAtMs > nowMs) return false;
  try {
    const stored = readFirstLiveCheckpoints(storage);
    if (!stored.writable) return false;
    const checkpoints = stored.checkpoints;
    const existing = checkpoints[normalized.providerId];
    if (existing && existing.liveRenderedAtMs <= nowMs
      && !isNewerCheckpoint(normalized, existing)) return false;
    checkpoints[normalized.providerId] = normalized;
    storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, JSON.stringify(checkpoints));
    return true;
  } catch {
    return false;
  }
}

function normalizeCheckpoint(value: unknown): FirstLiveCheckpoint | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const item = value as Record<string, unknown>;
  const {
    attemptId, providerId, source, setupSavedAtMs, probeStartedAtMs,
    freshResultReceivedAtMs, liveRenderedAtMs, appVersion, platform,
  } = item;
  if (typeof attemptId !== "string" || !UUID_PATTERN.test(attemptId)
    || typeof providerId !== "string" || !PROVIDER_IDS.has(providerId)
    || typeof source !== "string"
    || ALLOWED_SOURCES_BY_PROVIDER[providerId]?.has(source) !== true
    || !isTimestamp(setupSavedAtMs) || !isTimestamp(probeStartedAtMs)
    || setupSavedAtMs > probeStartedAtMs
    || !isTimestamp(freshResultReceivedAtMs)
    || probeStartedAtMs > freshResultReceivedAtMs
    || !isTimestamp(liveRenderedAtMs)
    || freshResultReceivedAtMs > liveRenderedAtMs
    || liveRenderedAtMs > Date.now() + MAX_FUTURE_SKEW_MS
    || typeof appVersion !== "string" || safeVersion(appVersion) !== appVersion
    || (platform !== "macos" && platform !== "linux")) return null;
  return {
    attemptId, providerId, source, setupSavedAtMs, probeStartedAtMs,
    freshResultReceivedAtMs, liveRenderedAtMs, appVersion, platform,
  };
}

function safeSource(providerId: string, detectedSource: string): string {
  if (ALLOWED_SOURCES_BY_PROVIDER[providerId]?.has(detectedSource) === true) return detectedSource;
  if (providerId === "claude") return "Claude Code / CLI";
  if (providerId === "codex") return "Codex login / CLI";
  return "Grok login / sessions";
}

function safeVersion(value: string): string | null {
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= 64
    && trimmed.toLowerCase() !== "unknown" && trimmed !== "—"
    && !CONTROL_PATTERN.test(trimmed) && APP_VERSION_PATTERN.test(trimmed) ? trimmed : null;
}

function isNewerCheckpoint(
  candidate: FirstLiveCheckpoint,
  existing: FirstLiveCheckpoint,
): boolean {
  if (candidate.attemptId === existing.attemptId) {
    return candidate.liveRenderedAtMs >= existing.liveRenderedAtMs;
  }
  if (candidate.setupSavedAtMs !== existing.setupSavedAtMs) {
    return candidate.setupSavedAtMs > existing.setupSavedAtMs;
  }
  return candidate.probeStartedAtMs > existing.probeStartedAtMs;
}

function isTimestamp(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function safeTimestamp(value: number): number {
  return isTimestamp(value) ? value : Math.max(1, Math.round(Date.now()));
}
