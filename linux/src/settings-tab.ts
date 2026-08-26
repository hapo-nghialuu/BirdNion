// Settings view — provider enable/disable + API key/cookie entry, persisted
// straight into the shared ~/.config/birdnion/settings.json (same schema as
// macOS, so the two apps can share one config).

import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import { emit, listen, type Event as TauriEvent } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { t, currentLang } from "./i18n";
import { reorderControls } from "./settings-provider-row";
import { logoMark } from "./logos";
import {
  lowestWindow,
  type ProviderRemediationTarget,
  type ProviderStatus,
} from "./provider-tab";
import {
  detailInfoGrid, usageSection, setupSection, quotaWarningCard, linksSection,
  codexAccountsCard, freemodelAccountsCard, antigravityAccountsCard, elevenlabsKeysCard, hiyoKeysCard,
  ANTIGRAVITY_ACCOUNT_CHANGED_EVENT, relativeUpdated, displayError,
  refreshMountedAntigravityAccountsCard,
  type AntigravityAccountChange,
  type ProviderCfg, type Settings,
} from "./settings-provider-detail";
import { GUIDED_SETUP_STATUS_EVENT } from "./action-center";
import { CODEX_ACCOUNT_CHANGED_EVENT } from "./settings-codex-accounts";
import {
  beginFirstLiveAttempt,
  checkpointDurationMs,
  canAcknowledgeVisiblePaint,
  completeFirstLiveAttempt,
  firstLivePhase,
  firstLivePersistenceResult,
  loadFirstLiveCheckpoints,
  saveFirstLiveCheckpoint,
  registerFirstLiveInvalidationBarrier,
  shouldApplyFirstLiveCompletion,
  shouldRetainFirstLiveTestOnInvalidation,
  type FirstLiveAttempt,
  type FirstLiveTestState,
} from "./first-live-checkpoint";
import {
  SETTINGS_SNAPSHOT_CHANGED_EVENT,
  saveRevisionedSettings,
} from "./settings-persistence";

/** Fired after settings.json provider list/order/enabled changes so the main
 * popover can rebuild tab strip order (macOS `.birdnionProvidersChanged`). */
export const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";

type OnboardingDetection = { isReady: boolean; source: string };
type GuidedSetupResult = {
  state: FirstLiveTestState;
  remediationTarget?: ProviderRemediationTarget;
  feedbackKey?: string;
};
const ONBOARDING_IDS = new Set(["claude", "codex", "grok"]);
const REMEDIATION_TARGETS = new Set<ProviderRemediationTarget>([
  "setupSource", "credential", "cookieSource",
]);
const ACTIVE_STATUS_IDENTITY_KEYS = new Map<string, keyof Settings>([
  ["codex", "active_codex_account"],
  ["freemodel", "active_freemodel_account"],
  ["elevenlabs", "active_elevenlabs_key"],
  ["hiyo", "active_hiyo_key"],
]);

export type ProviderSettingsGenerationToken = Readonly<{
  providerId: string;
  generation: number;
}>;

/** Latest-wins gate for async Settings status producers. A provider-account
 * event can invalidate one identity without cancelling unrelated providers. */
export function createProviderSettingsGenerationGate() {
  const generations = new Map<string, number>();
  const begin = (providerId: string): ProviderSettingsGenerationToken => {
    const generation = (generations.get(providerId) ?? 0) + 1;
    generations.set(providerId, generation);
    return { providerId, generation };
  };
  return {
    begin,
    beginRefresh(providerIds: readonly string[]) {
      const requested = new Set(providerIds);
      for (const providerId of generations.keys()) {
        if (!requested.has(providerId)) begin(providerId);
      }
      return new Map([...requested].map((providerId) => [providerId, begin(providerId)]));
    },
    invalidate(providerId: string) {
      begin(providerId);
    },
    isCurrent(token: ProviderSettingsGenerationToken) {
      return generations.get(token.providerId) === token.generation;
    },
  };
}

export function clearProviderSettingsStatus<
  TStatus extends { id: string },
  TRemediation,
>(
  statuses: readonly TStatus[],
  remediationTargets: Map<string, TRemediation>,
  providerId: string,
): TStatus[] {
  remediationTargets.delete(providerId);
  return statuses.filter((status) => status.id !== providerId);
}

function storedRemediationTarget(): ProviderRemediationTarget | null {
  const value = localStorage.getItem("birdnion.providerRemediationTarget");
  localStorage.removeItem("birdnion.providerRemediationTarget");
  return REMEDIATION_TARGETS.has(value as ProviderRemediationTarget)
    ? value as ProviderRemediationTarget
    : null;
}

type PersistedSettingsSave = {
  submitted: Settings;
  revision: number;
};

async function persistProvidersAndNotify(settings: Settings): Promise<PersistedSettingsSave> {
  let submitted: Settings | null = null;
  let persistedRevision: number | null = null;
  await saveRevisionedSettings(
    settings,
    async (snapshot) => {
      submitted = structuredClone(snapshot);
      persistedRevision = await invoke<number>("save_settings", { settings: submitted });
      return persistedRevision;
    },
  );
  if (!submitted || persistedRevision === null) {
    throw new Error("Settings save completed without a submitted snapshot");
  }
  await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
  return { submitted, revision: persistedRevision };
}

function afterVisiblePaint(): Promise<void> {
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  });
}

export async function installListenersBeforeLifecycleArm(
  registrations: Array<() => Promise<() => void>>,
  install: (unlisteners: Array<() => void>) => void,
  armLifecycle: () => void,
): Promise<void> {
  const unlisteners: Array<() => void> = [];
  try {
    for (const register of registrations) unlisteners.push(await register());
  } catch (error) {
    for (const unlisten of unlisteners.reverse()) unlisten();
    throw error;
  }
  install(unlisteners);
  armLifecycle();
}

/** Full roster (macOS parity), in default display order. */
const ROSTER: [string, string][] = [
  ["claude", "Claude"], ["codex", "Codex"], ["minimax", "MiniMax"],
  ["hapo", "Hapo AI Hub"], ["openrouter", "OpenRouter"], ["tryapi", "TryAPI"], ["deepseek", "DeepSeek"],
  ["zai", "z.ai"], ["elevenlabs", "ElevenLabs"], ["hiyo", "Hiyo"], ["deepgram", "Deepgram"],
  ["groq", "Groq"], ["grok", "Grok"], ["xai", "xAI"], ["openai", "OpenAI"], ["ollama", "Ollama"],
  ["copilot", "Copilot"], ["kilo", "Kilo"],
  ["commandcode", "CommandCode"], ["freemodel", "Freemodel"], ["mimo", "MiMo"],
  ["alibaba", "Alibaba"], ["cursor", "Cursor"], ["gemini", "Gemini"],
  ["kiro", "Kiro"], ["opencode", "OpenCode"], ["opencodego", "OpenCodeGo"],
  ["antigravity", "Antigravity"], ["bedrock", "Bedrock"],
];

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** id → display name; exported for the popover's placeholder tabs. */
export const NAME_BY_ID = new Map(ROSTER);

/** Provider ids in display order: whatever order is already persisted in
 * settings.json (so drag/arrow reordering sticks across reloads), then any
 * roster entries not yet present in the file, in roster order. */
function orderedIds(settings: Settings): string[] {
  const seen = new Set(settings.providers.map((p) => p.id));
  const fromFile = settings.providers.map((p) => p.id).filter((id) => NAME_BY_ID.has(id));
  const missing = ROSTER.map(([id]) => id).filter((id) => !seen.has(id));
  return [...fromFile, ...missing];
}

export type CanonicalSettingsReconciliation = {
  settings: Settings;
  conflicts: string[];
  hasLocalChanges: boolean;
};

export type CompletedSettingsSaveReconciliation = CanonicalSettingsReconciliation & {
  canonical: Settings;
};

function settingsValueEqual(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right)
      && left.length === right.length
      && left.every((value, index) => settingsValueEqual(value, right[index]));
  }
  if (typeof left !== "object" || left === null
    || typeof right !== "object" || right === null) return false;
  const leftRecord = left as Record<string, unknown>;
  const rightRecord = right as Record<string, unknown>;
  const leftKeys = Object.keys(leftRecord).sort();
  const rightKeys = Object.keys(rightRecord).sort();
  return settingsValueEqual(leftKeys, rightKeys)
    && leftKeys.every((key) => settingsValueEqual(leftRecord[key], rightRecord[key]));
}

/** Provider status identity changes carried by a complete canonical snapshot.
 * Compare provider config plus top-level active account/key selectors; revision,
 * ordering, and unrelated providers do not invalidate a cached status. */
export function changedProviderSettingsStatusIds(
  previous: Settings,
  next: Settings,
): string[] {
  const previousById = new Map(previous.providers.map((provider) => [provider.id, provider]));
  const nextById = new Map(next.providers.map((provider) => [provider.id, provider]));
  const providerIds = [...new Set([
    ...next.providers.map((provider) => provider.id),
    ...previous.providers.map((provider) => provider.id),
  ])];
  return providerIds.filter((providerId) => {
    if (!settingsValueEqual(previousById.get(providerId), nextById.get(providerId))) {
      return true;
    }
    const activeIdentityKey = ACTIVE_STATUS_IDENTITY_KEYS.get(providerId);
    return activeIdentityKey !== undefined
      && !settingsValueEqual(
        previous[activeIdentityKey] ?? null,
        next[activeIdentityKey] ?? null,
      );
  });
}

/** Rebase provider-form edits over a newer complete backend snapshot.
 * Unchanged fields stay canonical; colliding edits keep the draft but surface
 * a conflict so callers can block whole-document persistence. */
export function reconcileCanonicalSettingsSnapshot(
  base: Settings,
  local: Settings,
  canonical: Settings,
): CanonicalSettingsReconciliation {
  const merged = structuredClone(canonical);
  const conflicts: string[] = [];
  let hasLocalChanges = false;
  const baseById = new Map(base.providers.map((provider) => [provider.id, provider]));
  const localById = new Map(local.providers.map((provider) => [provider.id, provider]));
  const canonicalById = new Map(canonical.providers.map((provider) => [provider.id, provider]));
  const allIds = [...new Set([
    ...canonical.providers.map((provider) => provider.id),
    ...local.providers.map((provider) => provider.id),
    ...base.providers.map((provider) => provider.id),
  ])];
  const mergedById = new Map<string, ProviderCfg>();

  for (const id of allIds) {
    const baseProvider = baseById.get(id);
    const localProvider = localById.get(id);
    const canonicalProvider = canonicalById.get(id);
    if (!localProvider) {
      if (!baseProvider || !canonicalProvider) continue;
      hasLocalChanges = true;
      if (!settingsValueEqual(baseProvider, canonicalProvider)) conflicts.push(`providers.${id}`);
      continue;
    }
    if (!baseProvider) {
      if (canonicalProvider && settingsValueEqual(localProvider, canonicalProvider)) {
        mergedById.set(id, structuredClone(canonicalProvider));
      } else {
        hasLocalChanges = true;
        if (canonicalProvider) conflicts.push(`providers.${id}`);
        mergedById.set(id, structuredClone(localProvider));
      }
      continue;
    }
    if (!canonicalProvider) {
      if (!settingsValueEqual(localProvider, baseProvider)) {
        hasLocalChanges = true;
        conflicts.push(`providers.${id}`);
        mergedById.set(id, structuredClone(localProvider));
      }
      continue;
    }

    const result = structuredClone(canonicalProvider) as Record<string, unknown>;
    const baseRecord = baseProvider as unknown as Record<string, unknown>;
    const localRecord = localProvider as unknown as Record<string, unknown>;
    const canonicalRecord = canonicalProvider as unknown as Record<string, unknown>;
    const keys = new Set([
      ...Object.keys(baseRecord),
      ...Object.keys(localRecord),
      ...Object.keys(canonicalRecord),
    ]);
    for (const key of keys) {
      if (key === "id") continue;
      const baseHas = Object.prototype.hasOwnProperty.call(baseRecord, key);
      const localHas = Object.prototype.hasOwnProperty.call(localRecord, key);
      const canonicalHas = Object.prototype.hasOwnProperty.call(canonicalRecord, key);
      const localChanged = baseHas !== localHas
        || !settingsValueEqual(baseRecord[key], localRecord[key]);
      if (!localChanged) continue;
      if (localHas === canonicalHas
        && settingsValueEqual(localRecord[key], canonicalRecord[key])) continue;

      hasLocalChanges = true;
      const canonicalChanged = baseHas !== canonicalHas
        || !settingsValueEqual(baseRecord[key], canonicalRecord[key]);
      if (canonicalChanged) conflicts.push(`providers.${id}.${key}`);
      if (localHas) result[key] = structuredClone(localRecord[key]);
      else delete result[key];
    }
    mergedById.set(id, result as ProviderCfg);
  }

  const baseOrder = base.providers.map((provider) => provider.id);
  const localOrder = local.providers.map((provider) => provider.id);
  const canonicalOrder = canonical.providers.map((provider) => provider.id);
  const localOrderChanged = !settingsValueEqual(baseOrder, localOrder);
  let preferredOrder = canonicalOrder;
  if (localOrderChanged && !settingsValueEqual(localOrder, canonicalOrder)) {
    hasLocalChanges = true;
    if (!settingsValueEqual(baseOrder, canonicalOrder)) conflicts.push("providers.$order");
    preferredOrder = localOrder;
  }
  const mergedOrder = [...new Set([...preferredOrder, ...canonicalOrder, ...localOrder])];
  merged.providers = mergedOrder.flatMap((id) => {
    const provider = mergedById.get(id);
    return provider ? [provider] : [];
  });
  merged.settingsRevision = canonical.settingsRevision;
  return { settings: merged, conflicts: [...new Set(conflicts)].sort(), hasLocalChanges };
}

/** Treat exactly the immutable document sent to the backend as persisted.
 * Edits made against the live form while IPC is pending remain local deltas. */
export function reconcileCompletedSettingsSave(
  submitted: Settings,
  live: Settings,
  persistedRevision: number,
): CompletedSettingsSaveReconciliation {
  const canonical = structuredClone(submitted);
  canonical.settingsRevision = persistedRevision;
  return {
    canonical,
    ...reconcileCanonicalSettingsSnapshot(submitted, live, canonical),
  };
}

function settingsWithFullRoster(snapshot: Settings): Settings {
  const completed = structuredClone(snapshot);
  const byId = new Map(completed.providers.map((provider) => [provider.id, provider]));
  for (const id of orderedIds(completed)) {
    if (byId.has(id)) continue;
    const provider = { id };
    completed.providers.push(provider);
    byId.set(id, provider);
  }
  return completed;
}

/**
 * Providers tab — macOS ProvidersPane two-pane layout:
 * left sidebar (search + roster + enable + status) / right detail (header +
 * info + usage + settings fields).
 */
export async function providersPane(onSaved: () => void): Promise<HTMLElement> {
  const vi = currentLang() === "vi";
  const settings = await invoke<Settings>("get_settings").catch(() => ({
    version: 1,
    settingsRevision: Number.NaN,
    providers: [] as ProviderCfg[],
  }));
  // Ensure full roster present in memory.
  const byId = new Map(settings.providers.map((p) => [p.id, p]));
  for (const id of orderedIds(settings)) {
    if (!byId.has(id)) {
      const cfg = { id };
      settings.providers.push(cfg);
      byId.set(id, cfg);
    }
  }
  let canonicalSettings = structuredClone(settings);
  let formDirty = false;
  let settingsConflictPaths: string[] = [];

  const settingsConflictText = () => vi
    ? "Thiết lập đã đổi ở cửa sổ khác. Bản đang nhập được giữ, nhưng Lưu bị khóa để tránh ghi đè. Hãy sao chép thay đổi rồi mở lại Cài đặt."
    : "Settings changed in another window. Your draft is preserved, but Save is locked to prevent overwriting it. Copy the draft, then reopen Settings.";
  const conflictMatchesCanonical = (
    path: string,
    localSnapshot = settings,
    canonicalSnapshot = canonicalSettings,
  ): boolean => {
    if (path === "providers.$order") {
      return settingsValueEqual(
        localSnapshot.providers.map((provider) => provider.id),
        canonicalSnapshot.providers.map((provider) => provider.id),
      );
    }
    const parts = path.split(".");
    if (parts[0] !== "providers" || !parts[1]) return false;
    const localProvider = localSnapshot.providers.find((provider) => provider.id === parts[1]);
    const canonicalProvider = canonicalSnapshot.providers.find((provider) => provider.id === parts[1]);
    if (parts.length === 2) return settingsValueEqual(localProvider, canonicalProvider);
    const key = parts.slice(2).join(".");
    return settingsValueEqual(
      (localProvider as unknown as Record<string, unknown> | undefined)?.[key],
      (canonicalProvider as unknown as Record<string, unknown> | undefined)?.[key],
    );
  };
  const refreshLocalDraftState = () => {
    formDirty = reconcileCanonicalSettingsSnapshot(
      canonicalSettings,
      settings,
      canonicalSettings,
    ).hasLocalChanges;
    settingsConflictPaths = settingsConflictPaths.filter((path) => !conflictMatchesCanonical(path));
  };
  const persistCurrentSettingsAndNotify = async (): Promise<boolean> => {
    if (settingsConflictPaths.length > 0) throw new Error(settingsConflictText());
    const persisted = await persistProvidersAndNotify(settings);
    const liveCanonicalRevision = canonicalSettings.settingsRevision;
    if (Number.isSafeInteger(liveCanonicalRevision)
      && liveCanonicalRevision >= persisted.revision) {
      refreshLocalDraftState();
      return formDirty || settingsConflictPaths.length > 0;
    }

    const completion = reconcileCompletedSettingsSave(
      persisted.submitted,
      settings,
      persisted.revision,
    );
    canonicalSettings = completion.canonical;
    settings.settingsRevision = persisted.revision;
    formDirty = completion.hasLocalChanges;
    settingsConflictPaths = completion.conflicts;
    return formDirty || settingsConflictPaths.length > 0;
  };

  let selectedId = localStorage.getItem("birdnion.selectedProvider")
    || orderedIds(settings).find((id) => byId.get(id)?.enabled === true)
    || orderedIds(settings)[0]
    || "claude";
  // Shared with Settings window top search (`birdnion-sidebar-search`) —
  // no second search field in the provider roster.
  let searchQuery =
    typeof (window as { __birdnionSidebarSearch?: string }).__birdnionSidebarSearch === "string"
      ? (window as { __birdnionSidebarSearch?: string }).__birdnionSidebarSearch!
      : "";
  let statuses: ProviderStatus[] = [];
  const providerSettingsGenerations = createProviderSettingsGenerationGate();
  const detections = new Map<string, OnboardingDetection>();
  const onboardingTests = new Map<string, GuidedSetupResult>();
  const onboardingTestGenerations = new Map<string, number>();
  const firstLiveAttemptIDs = new Map<string, string>();
  const firstLiveCheckpoints = loadFirstLiveCheckpoints();
  const remediationTargets = new Map<string, ProviderRemediationTarget>();
  let pendingRemediationTarget = storedRemediationTarget();
  const clearProviderStatus = (providerId: string) => {
    statuses = clearProviderSettingsStatus(statuses, remediationTargets, providerId);
  };

  const invalidateOnboardingTest = (providerId: string) => {
    onboardingTestGenerations.set(
      providerId,
      (onboardingTestGenerations.get(providerId) ?? 0) + 1,
    );
    firstLiveAttemptIDs.delete(providerId);
    // Keep the `.testing` entry as the in-flight registry until the old IPC
    // promise settles. Tauri invoke is not cancellable; deleting it here
    // would allow disable -> re-enable -> second overlapping probe.
    if (!shouldRetainFirstLiveTestOnInvalidation(
      onboardingTests.get(providerId)?.state,
    )) {
      onboardingTests.delete(providerId);
    }
  };

  const root = el("div", "pp-root");
  const sidebar = el("div", "pp-sidebar");
  const detail = el("div", "pp-detail");
  root.append(sidebar, detail);
  const invalidateSelectedConfigurationState = (): string | null => {
    const providerId = selectedId;
    providerSettingsGenerations.invalidate(providerId);
    if (!ONBOARDING_IDS.has(providerId)) return null;
    invalidateOnboardingTest(providerId);
    return providerId;
  };
  const invalidateSelectedConfiguration = (event: Event) => {
    const target = event.target;
    const editsProviderSettings = target instanceof Element
      && (target.closest(".pp-setup-wrap") !== null || target.matches(".sw-switch"));
    if (editsProviderSettings) {
      // setupSection commits text fields on `change`. Mirror that callback on
      // each keystroke without bubbling/re-rendering, so an async canonical
      // snapshot can rebase the actual draft instead of the previous value.
      if (event.type === "input" && target instanceof HTMLInputElement
        && target.matches(".pp-field-input")) {
        target.dispatchEvent(new Event("change"));
      }
      refreshLocalDraftState();
    }
    const providerId = invalidateSelectedConfigurationState();
    if (!providerId) return;
    if (event.type === "change") {
      // `change` runs after the control committed, so a full render is safe.
      renderDetail();
    } else {
      // Rebuilding the whole form on each keystroke would steal focus. Strip
      // stale LIVE/current evidence in place on `input` instead.
      refreshInvalidatedOnboardingEvidence(providerId);
    }
  };
  // Bind First Live to the configuration that started its probe. Settings
  // controls bubble here, so source/credential edits invalidate in-flight
  // generations without hashing or persisting any secret.
  detail.addEventListener("input", invalidateSelectedConfiguration);
  detail.addEventListener("change", invalidateSelectedConfiguration);

  const focusRemediation = (target: ProviderRemediationTarget) => {
    pendingRemediationTarget = null;
    requestAnimationFrame(() => {
      const exactControl = detail.querySelector<HTMLElement>(
        `input[data-remediation-target="${target}"], select[data-remediation-target="${target}"], button[data-remediation-target="${target}"]`,
      );
      const destination = exactControl
        ?? detail.querySelector<HTMLElement>(`[data-remediation-target="${target}"]`)
        ?? detail.querySelector<HTMLElement>(`[data-remediation-targets~="${target}"]`);
      if (!destination) return;
      destination.scrollIntoView({ behavior: "smooth", block: "center" });
      destination.focus({ preventScroll: true });
      destination.classList.add("guided-remediation-focus");
      destination.addEventListener("animationend", () => {
        destination.classList.remove("guided-remediation-focus");
      }, { once: true });
    });
  };

  const onSharedSearch = ((ev: CustomEvent<string>) => {
    searchQuery = ev.detail ?? "";
    renderSidebar();
  }) as EventListener;
  window.addEventListener("birdnion-sidebar-search", onSharedSearch);

  const statusById = () => new Map(statuses.map((s) => [s.id, s]));

  const refreshInvalidatedOnboardingEvidence = (providerId: string) => {
    if (selectedId !== providerId) return;
    const explicit = onboardingTests.get(providerId) ?? { state: "idle" as const };
    const detection = detections.get(providerId) ?? { isReady: false, source: "" };
    const phase = firstLivePhase(
      explicit.state,
      Boolean(statusById().get(providerId)?.error),
      detection.isReady,
    );
    const status = detail.querySelector<HTMLElement>(".pp-onboarding-status");
    if (!status) return;
    status.className = `pp-onboarding-status ${phase}`;
    status.textContent = phase === "readyToTest"
      ? t("guidedSetupDetected", { source: detection.source })
      : t(`guidedSetup.${phase}`);

    const note = detail.querySelector<HTMLElement>(".pp-onboarding-card > .pp-field-hint");
    if (note) note.textContent = t("guidedSetupPrivacyNote");
    const receipt = detail.querySelector<HTMLElement>(".pp-onboarding-receipt");
    const checkpoint = firstLiveCheckpoints[providerId];
    if (receipt && checkpoint) {
      receipt.classList.remove("current");
      receipt.textContent = firstLiveCheckpointText(checkpoint, false);
    }
    const connect = detail.querySelector<HTMLButtonElement>(
      ".pp-onboarding-actions .save-button",
    );
    if (connect) {
      connect.disabled = phase === "testing";
      connect.textContent = phase === "failed" ? t("guidedSetupRetry") : t("guidedSetupConnect");
    }
  };

  // Account switches/removals/saves may originate in this card or another
  // Tauri window. They change the credential identity under an active Codex
  // probe, so bump its generation before that result can mint a receipt.
  const handleCodexAccountChange = () => {
    providerSettingsGenerations.invalidate("codex");
    clearProviderStatus("codex");
    invalidateOnboardingTest("codex");
    if (root.isConnected) {
      renderSidebar();
      if (selectedId === "codex") renderDetail();
    }
  };
  const handleAntigravityAccountChange = (event: TauriEvent<AntigravityAccountChange>) => {
    providerSettingsGenerations.invalidate("antigravity");
    clearProviderStatus("antigravity");
    if (event.payload.origin !== "settings" && root.isConnected) {
      renderSidebar();
      if (selectedId === "antigravity") refreshMountedAntigravityAccountsCard();
    }
  };
  let unlistenCodexAccountChanges: (() => void) | null = null;
  let unlistenAntigravityAccountChanges: (() => void) | null = null;
  let unlistenSettingsSnapshotChanges: (() => void) | null = null;

  // providersPane can be rebuilt repeatedly while navigating Settings. Drop
  // both global listeners as soon as this concrete pane leaves the document;
  // otherwise every visit retains the entire old settings/status closure.
  let wasConnected = false;
  let disposed = false;
  const disposePaneListeners = () => {
    if (disposed) return;
    disposed = true;
    observer.disconnect();
    unlistenCodexAccountChanges?.();
    unlistenAntigravityAccountChanges?.();
    unlistenSettingsSnapshotChanges?.();
    window.removeEventListener("birdnion-sidebar-search", onSharedSearch);
  };
  const observer = new MutationObserver(() => {
    if (root.isConnected) {
      wasConnected = true;
    } else if (wasConnected) {
      disposePaneListeners();
    }
  });

  /**
   * Sidebar order (macOS ProvidersPane.visibleRows parity):
   * 1. **Enabled** first — user custom order from settings.providers / arrow reorder
   * 2. **Disabled** after — A→Z by display name
   */
  const visibleIds = (): string[] => {
    const q = searchQuery.trim().toLowerCase();
    const ids = orderedIds(settings);
    const filtered = ids.filter((id) => {
      if (!q) return true;
      const name = sidebarName(id).toLowerCase();
      return name.includes(q) || id.includes(q);
    });
    // Active: keep file/roster order (reorder arrows rewrite settings.providers).
    const active = filtered.filter((id) => byId.get(id)?.enabled === true);
    // Inactive: alphabet so the long disabled list is scannable.
    const inactive = filtered
      .filter((id) => byId.get(id)?.enabled !== true)
      .sort((a, b) =>
        sidebarName(a).localeCompare(sidebarName(b), undefined, { sensitivity: "base" }),
      );
    return [...active, ...inactive];
  };

  /** Name shown in the sidebar row — prefer custom displayName (e.g. Hapo). */
  const sidebarName = (id: string): string => {
    const cfg = byId.get(id);
    const custom = cfg?.displayName?.trim();
    if (custom) return custom;
    return NAME_BY_ID.get(id) ?? id;
  };

  const subtitleFor = (id: string): {
    text: string; isError: boolean; quotaClass?: string;
  } => {
    const st = statusById().get(id);
    const cfg = byId.get(id);
    if (cfg?.enabled !== true) {
      return { text: t("provider.disabled"), isError: false };
    }
    if (st?.error) {
      const msg = displayError(st.error);
      return { text: msg.slice(0, 40) + (msg.length > 40 ? "…" : ""), isError: true };
    }
    if (st && st.windows.length > 0) {
      // `st.windows.length > 0` guarantees lowestWindow returns non-null.
      const lowest = lowestWindow(st)!;
      const pct = lowest.remainingPct;
      // Quota % colored by level in the list (P4 reskin).
      const quotaClass = pct <= 20 ? "critical" : pct <= 50 ? "warning" : "ok";
      return {
        text: t("provider.remainingPct", { n: pct }),
        isError: false,
        quotaClass,
      };
    }
    return { text: t("provider.noDataShort"), isError: false };
  };

  const renderSidebar = () => {
    sidebar.textContent = "";
    const list = el("div", "pp-sidebar-list");
    for (const id of visibleIds()) {
      const cfg = byId.get(id)!;
      const name = sidebarName(id);
      const row = el("div", `pp-side-row${id === selectedId ? " selected" : ""}`);
      row.dataset.id = id;

      const check = document.createElement("input");
      check.type = "checkbox";
      check.className = "pp-check";
      check.checked = cfg.enabled === true;
      check.addEventListener("click", (ev) => ev.stopPropagation());
      check.addEventListener("change", () => {
        cfg.enabled = check.checked;
        refreshLocalDraftState();
        if (!check.checked) invalidateOnboardingTest(id);
        renderSidebar();
        renderDetail();
      });

      // macOS sidebarLogoTint: enabled → dark/black mono; disabled → gray mono.
      // (Never use brand multi-color marks in the sidebar.)
      const enabled = cfg.enabled === true;
      const logo = logoMark(
        id,
        `pp-side-logo tab-logo-mono${enabled ? " pp-logo-on" : " pp-logo-off"}`,
      );
      const text = el("div", "pp-side-text");
      const nameEl = el("div", `pp-side-name${enabled ? "" : " off"}`, name);
      text.append(nameEl);
      const sub = subtitleFor(id);
      const subCls = [
        "pp-side-sub",
        sub.isError ? "error" : "",
        sub.quotaClass ? `quota-${sub.quotaClass}` : "",
      ].filter(Boolean).join(" ");
      const subEl = el("div", subCls, sub.text);
      text.append(subEl);

      const dot = el("span", `pp-dot${cfg.enabled !== true ? " off" : sub.isError ? " warn" : " ok"}`);

      row.append(check, logo, text, dot);
      // Reorder arrows on the selected **enabled** row only — swaps among
      // active peers (same order as popover tabs). Persists immediately
      // (macOS drag-drop finish) so tabs stay in sync.
      if (id === selectedId && cfg.enabled === true) {
        row.append(reorderControls(settings.providers, cfg, () => {
          refreshLocalDraftState();
          renderSidebar();
          void persistCurrentSettingsAndNotify()
            .then(() => onSaved())
            .catch(() => {});
        }, true));
      }
      row.addEventListener("click", () => {
        if (id !== selectedId) invalidateOnboardingTest(selectedId);
        selectedId = id;
        localStorage.setItem("birdnion.selectedProvider", id);
        renderSidebar();
        renderDetail();
      });
      list.append(row);
    }
    sidebar.append(list);
  };

  const renderDetail = () => {
    detail.textContent = "";
    const cfg = byId.get(selectedId);
    if (!cfg) {
      detail.append(el("div", "pp-empty", t("provider.choose")));
      return;
    }
    const name = NAME_BY_ID.get(selectedId) ?? selectedId;
    const st = statusById().get(selectedId);
    const enabled = cfg.enabled === true;
    const scroll = el("div", "pp-detail-scroll");

    const runConnectionTest = async () => {
      const providerId = selectedId;
      if (onboardingTests.get(providerId)?.state === "testing") return;
      const generation = (onboardingTestGenerations.get(providerId) ?? 0) + 1;
      onboardingTestGenerations.set(providerId, generation);
      const isCurrentEnabledTest = () =>
        shouldApplyFirstLiveCompletion(
          providerId,
          generation,
          onboardingTestGenerations.get(providerId),
          selectedId,
          byId.get(providerId)?.enabled === true,
        );
      const rejectStaleCompletion = () => {
        if (isCurrentEnabledTest()) return false;
        if (onboardingTestGenerations.get(providerId) !== generation
          && onboardingTests.get(providerId)?.state === "testing") {
          onboardingTests.delete(providerId);
        }
        if (selectedId === providerId) renderDetail();
        return true;
      };
      onboardingTests.set(providerId, { state: "testing" });
      firstLiveAttemptIDs.delete(providerId);
      renderDetail();
      const wasEnabled = cfg.enabled;
      cfg.enabled = true;
      try {
        await persistCurrentSettingsAndNotify();
      } catch {
        if (rejectStaleCompletion()) return;
        cfg.enabled = wasEnabled;
        onboardingTests.set(providerId, {
          state: "failed",
          feedbackKey: "guidedSetupSaveFailed",
        });
        renderSidebar();
        if (selectedId === providerId) renderDetail();
        return;
      }
      // The backend now owns the submitted identity. Fail closed before the
      // fresh probe so prior-account quota cannot remain visible if it stalls.
      providerSettingsGenerations.invalidate(providerId);
      clearProviderStatus(providerId);
      renderSidebar();
      if (selectedId === providerId) renderDetail();
      const setupSavedAtMs = Date.now();
      const appVersion = await getVersion().catch(() => "unknown");
      if (rejectStaleCompletion()) return;
      const attempt = beginFirstLiveAttempt({
        providerId,
        detectedSource: detections.get(providerId)?.source ?? "",
        setupSavedAtMs,
        probeStartedAtMs: Date.now(),
        appVersion,
      });
      let receiptInput: {
        attempt: FirstLiveAttempt;
        freshResultReceivedAtMs: number;
      } | null = null;
      try {
        const result = await invoke<ProviderStatus>("test_provider", { id: providerId });
        const freshResultReceivedAtMs = Date.now();
        if (rejectStaleCompletion()) return;
        if (result.id !== providerId) {
          throw new Error("Provider self-test returned a mismatched identity");
        }
        const index = statuses.findIndex((item) => item.id === providerId);
        if (index >= 0) statuses[index] = result;
        else statuses.push(result);
        const target = result.error
          ? await invoke<ProviderRemediationTarget | null>("provider_remediation_target", {
            providerId,
            raw: result.error,
          }).catch(() => null)
          : null;
        if (rejectStaleCompletion()) return;
        await emit(GUIDED_SETUP_STATUS_EVENT, result).catch(() => {});
        if (rejectStaleCompletion()) return;
        if (result.error || result.windows.length === 0) {
          firstLiveAttemptIDs.delete(providerId);
          onboardingTests.set(providerId, {
            state: "failed",
            remediationTarget: target ?? undefined,
          });
        } else if (attempt) {
          onboardingTests.set(providerId, { state: "live" });
          firstLiveAttemptIDs.set(providerId, attempt.attemptId);
          receiptInput = { attempt, freshResultReceivedAtMs };
        } else {
          onboardingTests.set(providerId, firstLivePersistenceResult(false));
        }
        renderSidebar();
        onSaved();
      } catch {
        receiptInput = null;
        firstLiveAttemptIDs.delete(providerId);
        if (rejectStaleCompletion()) return;
        onboardingTests.set(providerId, {
          state: "failed",
          feedbackKey: "guidedSetupTestFailed",
        });
      }
      if (selectedId === providerId) renderDetail();
      if (receiptInput && isCurrentEnabledTest()) {
        const failUndurableReceipt = () => {
          if (!isCurrentEnabledTest()) return;
          firstLiveAttemptIDs.delete(providerId);
          onboardingTests.set(providerId, firstLivePersistenceResult(false));
          renderSidebar();
          if (selectedId === providerId) renderDetail();
        };
        const liveStatus = detail.querySelector<HTMLElement>(".pp-onboarding-status.live");
        if (!liveStatus) {
          failUndurableReceipt();
          return;
        }
        // Two animation frames acknowledge a browser paint containing the
        // current Live node. Native visibility/focus closes the gap where a
        // covered or minimized Tauri webview still reports DOM `visible`.
        await afterVisiblePaint();
        if (!liveStatus.isConnected || !isCurrentEnabledTest()) {
          failUndurableReceipt();
          return;
        }
        const nativeWindow = getCurrentWindow();
        const [nativeVisible, nativeMinimized, nativeFocused] = await Promise.all([
          nativeWindow.isVisible(),
          nativeWindow.isMinimized(),
          nativeWindow.isFocused(),
        ]).catch(() => [false, true, false] as const);
        if (!canAcknowledgeVisiblePaint(
          document.visibilityState === "visible",
          nativeVisible,
          nativeMinimized,
          nativeFocused,
        ) || !liveStatus.isConnected || !isCurrentEnabledTest()) {
          failUndurableReceipt();
          return;
        }
        const checkpoint = completeFirstLiveAttempt(
          receiptInput.attempt,
          receiptInput.freshResultReceivedAtMs,
          Date.now(),
        );
        const saved = saveFirstLiveCheckpoint(checkpoint);
        onboardingTests.set(providerId, firstLivePersistenceResult(saved));
        if (saved) {
          firstLiveCheckpoints[providerId] = checkpoint;
        } else {
          firstLiveAttemptIDs.delete(providerId);
        }
        renderSidebar();
        if (selectedId === providerId) renderDetail();
      }
    };

    const onboardingCard = (): HTMLElement | null => {
      if (!ONBOARDING_IDS.has(selectedId)) return null;
      const detection = detections.get(selectedId) ?? { isReady: false, source: "" };
      const explicit = onboardingTests.get(selectedId) ?? { state: "idle" as const };
      const phase = firstLivePhase(explicit.state, Boolean(st?.error), detection.isReady);
      const label = phase === "readyToTest"
        ? t("guidedSetupDetected", { source: detection.source })
        : t(`guidedSetup.${phase}`);
      const target = phase === "needsSource"
        ? "setupSource"
        : phase === "failed"
          ? remediationTargets.get(selectedId)
            ?? (explicit.state === "failed" ? explicit.remediationTarget : undefined)
          : undefined;
      const group = el("div", "sw-group pp-onboarding");
      group.append(el("div", "sw-section-header", t("guidedSetupHeader")));
      const card = el("div", "sw-card pp-onboarding-card");
      const status = el("div", `pp-onboarding-status ${phase}`, label);
      const note = el("div", "pp-field-hint", t("guidedSetupPrivacyNote"));
      if (explicit.feedbackKey) note.textContent = t(explicit.feedbackKey);
      const checkpoint = firstLiveCheckpoints[selectedId];
      const isCurrentCheckpoint = phase === "live"
        && checkpoint?.attemptId === firstLiveAttemptIDs.get(selectedId);
      const receipt = checkpoint
        ? el("div", `pp-onboarding-receipt${isCurrentCheckpoint ? " current" : ""}`,
          firstLiveCheckpointText(checkpoint, isCurrentCheckpoint))
        : null;
      const actions = el("div", "pp-onboarding-actions");
      const connect = el("button", "save-button",
        phase === "failed" ? t("guidedSetupRetry") : t("guidedSetupConnect"));
      connect.toggleAttribute("disabled", phase === "testing");
      connect.addEventListener("click", () => { void runConnectionTest(); });
      actions.append(connect);
      if (target) {
        const fix = el("button", "sw-pill-btn", t("guidedSetupFix"));
        fix.addEventListener("click", () => focusRemediation(target));
        actions.append(fix);
      }
      card.append(status, note);
      if (receipt) card.append(receipt);
      card.append(actions);
      group.append(card);
      return group;
    };

    // Header card — macOS detailHeader: logo + name + "version • updated"
    // subtitle + self-test (inline result) + reload + enable switch.
    const head = el("div", "sw-card pp-head-card");
    const headRow = el("div", "pp-head-row");
    headRow.append(logoMark(selectedId, "pp-detail-logo"));
    const titles = el("div", "pp-head-titles");
    titles.append(el("div", "pp-head-name", name));
    const subParts = [st?.version, relativeUpdated(st?.lastUpdated)].filter(Boolean) as string[];
    titles.append(el("div", "pp-head-sub",
      subParts.length > 0 ? subParts.join(" • ") : (enabled ? t("provider.notLoaded") : t("provider.disabled"))));
    headRow.append(titles);

    const actions = el("div", "pp-head-actions");
    const testBtn = el("button", "sw-pill-btn", t("provider.selfTest"));
    const testResult = el("div", "pp-selftest-result");
    testBtn.addEventListener("click", async () => {
      const providerId = selectedId;
      const providerGeneration = providerSettingsGenerations.begin(providerId);
      const isCurrentProviderRequest = () =>
        providerSettingsGenerations.isCurrent(providerGeneration);
      const isCurrentResultNode = () =>
        isCurrentProviderRequest()
        && selectedId === providerId
        && testResult.isConnected;
      testResult.className = "pp-selftest-result running";
      testResult.textContent = t("provider.selfTest.running");
      try {
        const res = await invoke<ProviderStatus>("test_provider", { id: providerId });
        if (res.id !== providerId) throw new Error("Provider self-test response mismatch");
        let resultClass = "pp-selftest-result pass";
        let resultText = t("provider.selfTest.pass");
        let resultTitle = "";
        if (res.error || res.windows.length === 0) {
          const raw = res.error || (vi ? "Provider không trả dữ liệu quota." : "Provider returned no quota data.");
          const suffix = (await invoke<string | null>("classify_provider_error", { raw }).catch(() => null)) ?? "unknown";
          resultClass = "pp-selftest-result fail";
          resultText = `${t("provider.selfTest.fail")} — ${t(`providerError.${suffix}.hint`)}`;
          resultTitle = displayError(raw);
        }
        if (!isCurrentProviderRequest()) return;
        // Refresh only the provider that started this probe. `selectedId` is
        // mutable while IPC/classification await, and account changes can keep
        // the same id/node while changing the provider identity underneath it.
        const idx = statuses.findIndex((s) => s.id === providerId);
        if (idx >= 0) statuses[idx] = res;
        else statuses.push(res);
        renderSidebar();
        if (!isCurrentResultNode()) return;
        testResult.className = resultClass;
        testResult.textContent = resultText;
        testResult.title = resultTitle;
      } catch (err) {
        if (!isCurrentResultNode()) return;
        testResult.className = "pp-selftest-result fail";
        testResult.textContent = `${t("provider.selfTest.fail")} — ${String(err)}`;
      }
    });
    const reloadBtn = el("button", "sw-icon-btn");
    reloadBtn.title = t("provider.reload");
    reloadBtn.textContent = "↻";
    reloadBtn.addEventListener("click", () => { void refreshStatuses().then(() => { renderSidebar(); renderDetail(); }); });

    const enable = document.createElement("input");
    enable.type = "checkbox";
    enable.className = "sw-switch";
    enable.checked = enabled;
    enable.addEventListener("change", () => {
      cfg.enabled = enable.checked;
      if (!enable.checked) invalidateOnboardingTest(selectedId);
      renderSidebar();
      renderDetail();
    });

    actions.append(testBtn, reloadBtn, enable);
    headRow.append(actions);
    head.append(headRow);
    head.append(testResult);
    scroll.append(head);

    const onboarding = onboardingCard();
    if (onboarding) scroll.append(onboarding);

    // macOS detail-column order: info grid → usage → setup → (codex
    // accounts card) → warnings → links.
    scroll.append(detailInfoGrid(selectedId, enabled, st));
    scroll.append(usageSection(selectedId, enabled, st));
    scroll.append(setupSection(cfg, vi));
    if (selectedId === "codex") scroll.append(codexAccountsCard());
    if (selectedId === "freemodel") scroll.append(freemodelAccountsCard());
    if (selectedId === "antigravity") scroll.append(antigravityAccountsCard());
    if (selectedId === "elevenlabs") {
      const keys = elevenlabsKeysCard();
      keys.dataset.remediationTarget = "credential";
      keys.tabIndex = -1;
      scroll.append(keys);
    }
    if (selectedId === "hiyo") {
      const keys = hiyoKeysCard();
      keys.dataset.remediationTarget = "credential";
      keys.tabIndex = -1;
      scroll.append(keys);
    }
    scroll.append(quotaWarningCard(selectedId));
    const links = linksSection(selectedId);
    if (links) scroll.append(links);

    // Save
    const saveRow = el("div", "pp-save-row");
    const save = el("button", "save-button", t("settingsSave")) as HTMLButtonElement;
    if (settingsConflictPaths.length > 0) {
      save.disabled = true;
      save.textContent = vi ? "Xung đột — mở lại Cài đặt" : "Conflict — reopen Settings";
    }
    save.addEventListener("click", async () => {
      const providerId = selectedId;
      const providerConfigChanged = !settingsValueEqual(
        canonicalSettings.providers.find((provider) => provider.id === providerId),
        settings.providers.find((provider) => provider.id === providerId),
      );
      save.textContent = "…";
      save.disabled = true;
      invalidateSelectedConfigurationState();
      try {
        const hasRemainingDraft = await persistCurrentSettingsAndNotify();
        const feedback = hasRemainingDraft
          ? (vi ? "Đã lưu bản trước — còn thay đổi mới" : "Previous draft saved — newer edits pending")
          : t("settingsSaved");
        save.textContent = feedback;
        save.disabled = settingsConflictPaths.length > 0;
        if (providerConfigChanged) {
          // Re-invalidate at durable completion: a refresh may have started
          // while save IPC was pending against the previous backend identity.
          providerSettingsGenerations.invalidate(providerId);
          clearProviderStatus(providerId);
          renderSidebar();
          if (selectedId === providerId) {
            renderDetail();
            const visibleSave = detail.querySelector<HTMLButtonElement>(
              ".pp-save-row > .save-button",
            );
            if (visibleSave) {
              visibleSave.textContent = feedback;
              visibleSave.disabled = settingsConflictPaths.length > 0;
            }
          }
        }
        setTimeout(onSaved, 300);
        void refreshStatuses().then(() => { renderSidebar(); renderDetail(); });
      } catch (err) {
        save.textContent = `${t("loadError")}: ${err}`;
        save.disabled = settingsConflictPaths.length > 0;
      }
    });
    saveRow.append(save);
    scroll.append(saveRow);
    if (settingsConflictPaths.length > 0) {
      const conflict = el("div", "pp-field-hint", settingsConflictText());
      conflict.setAttribute("role", "alert");
      scroll.append(conflict);
    }

    detail.append(scroll);
    if (pendingRemediationTarget) focusRemediation(pendingRemediationTarget);
  };

  async function refreshStatuses() {
    // Fetch all known ids that are enabled (or all) for sidebar subtitles.
    const ids = orderedIds(settings).filter((id) => byId.get(id)?.enabled === true);
    const enabledIds = new Set(ids);
    const generations = providerSettingsGenerations.beginRefresh(ids);
    statuses = statuses.filter((status) => enabledIds.has(status.id));
    for (const providerId of remediationTargets.keys()) {
      if (!enabledIds.has(providerId)) remediationTargets.delete(providerId);
    }
    if (ids.length === 0) {
      statuses = [];
      return;
    }

    const fetched = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
    const freshStatuses = Array.isArray(fetched) ? fetched : [];
    const currentIds = ids.filter((providerId) => {
      const token = generations.get(providerId);
      return token !== undefined && providerSettingsGenerations.isCurrent(token);
    });
    if (currentIds.length === 0) return;

    const currentIdSet = new Set(currentIds);
    const freshById = new Map(freshStatuses
      .filter((status) => currentIdSet.has(status.id))
      .map((status) => [status.id, status]));
    statuses = [
      ...statuses.filter((status) => !currentIdSet.has(status.id)),
      ...currentIds.flatMap((providerId) => {
        const status = freshById.get(providerId);
        return status ? [status] : [];
      }),
    ];
    for (const providerId of currentIds) remediationTargets.delete(providerId);
    await Promise.all(currentIds.map(async (providerId) => {
      const status = freshById.get(providerId);
      if (!status?.error) return;
      const target = await invoke<ProviderRemediationTarget | null>("provider_remediation_target", {
        providerId,
        raw: status.error,
      }).catch(() => null);
      const token = generations.get(providerId);
      if (target && token && providerSettingsGenerations.isCurrent(token)) {
        remediationTargets.set(providerId, target);
      }
    }));
  }

  const applyCanonicalSettingsSnapshot = (fresh: Settings) => {
    if (!Array.isArray(fresh.providers) || !Number.isSafeInteger(fresh.settingsRevision)
      || fresh.settingsRevision < 0) return;
    const currentRevision = canonicalSettings.settingsRevision;
    if (Number.isSafeInteger(currentRevision) && fresh.settingsRevision <= currentRevision) return;

    const completedCanonical = settingsWithFullRoster(fresh);
    for (const providerId of changedProviderSettingsStatusIds(
      canonicalSettings,
      completedCanonical,
    )) {
      providerSettingsGenerations.invalidate(providerId);
      invalidateOnboardingTest(providerId);
      clearProviderStatus(providerId);
    }
    const priorConflicts = settingsConflictPaths;
    const reconciled = formDirty || priorConflicts.length > 0
      ? reconcileCanonicalSettingsSnapshot(canonicalSettings, settings, completedCanonical)
      : {
          settings: completedCanonical,
          conflicts: [] as string[],
          hasLocalChanges: false,
        };

    // Account/key commands mutate settings.json behind this pane. Clean fields
    // take the complete canonical document; only actual provider-form deltas
    // are rebased. Same-field collisions remain visible and block persistence.
    for (const key of Object.keys(settings)) {
      delete (settings as unknown as Record<string, unknown>)[key];
    }
    Object.assign(settings, reconciled.settings);
    canonicalSettings = structuredClone(completedCanonical);
    settingsConflictPaths = [...new Set([
      ...priorConflicts.filter((path) => !conflictMatchesCanonical(
        path,
        reconciled.settings,
        completedCanonical,
      )),
      ...reconciled.conflicts,
    ])].sort();
    formDirty = reconciled.hasLocalChanges;
    byId.clear();
    for (const provider of settings.providers) byId.set(provider.id, provider);
    if (!byId.has(selectedId)) {
      selectedId = orderedIds(settings).find((id) => byId.get(id)?.enabled === true)
        ?? orderedIds(settings)[0]
        ?? "claude";
      localStorage.setItem("birdnion.selectedProvider", selectedId);
    }
    renderSidebar();
    renderDetail();
    void refreshStatuses().then(() => { renderSidebar(); renderDetail(); });
  };

  await installListenersBeforeLifecycleArm(
    [
      () => registerFirstLiveInvalidationBarrier(
        (handler) => listen(CODEX_ACCOUNT_CHANGED_EVENT, handler),
        handleCodexAccountChange,
      ),
      () => listen<AntigravityAccountChange>(
        ANTIGRAVITY_ACCOUNT_CHANGED_EVENT,
        handleAntigravityAccountChange,
      ),
      () => listen<Settings>(
        SETTINGS_SNAPSHOT_CHANGED_EVENT,
        ({ payload }) => applyCanonicalSettingsSnapshot(payload),
      ),
    ],
    ([codexUnlisten, antigravityUnlisten, settingsUnlisten]) => {
      unlistenCodexAccountChanges = codexUnlisten;
      unlistenAntigravityAccountChanges = antigravityUnlisten;
      unlistenSettingsSnapshotChanges = settingsUnlisten;
    },
    () => {
      // Arm lifecycle disposal only after every awaited listener is registered.
      // Otherwise a slow second `listen()` can cross the first animation frame,
      // dispose the Codex barrier before this pane mounts, and leak the late
      // settings listener with no way to invalidate First Live.
      observer.observe(document.documentElement, { childList: true, subtree: true });
      requestAnimationFrame(() => {
        if (root.isConnected) wasConnected = true;
        else disposePaneListeners();
      });
    },
  );

  // Initial paint + background status fetch
  renderSidebar();
  renderDetail();
  for (const id of ONBOARDING_IDS) {
    void invoke<OnboardingDetection>("provider_onboarding_detection", { id })
      .then((result) => { detections.set(id, result); if (id === selectedId) renderDetail(); })
      .catch(() => {});
  }
  void refreshStatuses().then(() => { renderSidebar(); renderDetail(); });

  return root;
}

function firstLiveCheckpointText(
  checkpoint: ReturnType<typeof loadFirstLiveCheckpoints>[string],
  isCurrent: boolean,
): string {
  const seconds = checkpointDurationMs(checkpoint) / 1_000;
  const duration = `${seconds < 10 ? seconds.toFixed(1) : seconds.toFixed(0)}s`;
  const detail = `${checkpoint.source} · ${duration}`;
  if (isCurrent) return detail;
  const ageDays = Math.floor(Math.max(0, Date.now() - checkpoint.liveRenderedAtMs) / 86_400_000);
  const time = ageDays > 0
    ? t("provider.daysAgo", { n: ageDays })
    : relativeUpdated(checkpoint.liveRenderedAtMs) ?? "—";
  return t("guidedSetupLastVerified", {
    time,
    detail,
  });
}

/** @deprecated in-popover settings — use open_settings_window + settingsWindowRoot */
export async function settingsTab(onSaved: () => void, onRefreshNow: () => void): Promise<HTMLElement> {
  void onRefreshNow;
  return providersPane(onSaved);
}
