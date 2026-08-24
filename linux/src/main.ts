import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-sans/700.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "@fontsource/ibm-plex-mono/600.css";
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { combine, scanFreshness, UsageReport, UsageSourceId } from "./usage";
import {
  chartCard, budgetForecastCard, providerBudgetCard, allChartDays,
} from "./all-tab";
import {
  providerCard,
  claudeCodeQuickApplyCard,
  loadingSkeleton,
  lowestWindow,
  serviceStatusStrip,
  ProviderStatus,
  StaleQuotaWarning,
  type ProviderRemediationTarget,
} from "./provider-tab";
import { freemodelAccountsPopoverCard } from "./freemodel-accounts-popover";
import { elevenlabsKeysPopoverCard } from "./elevenlabs-keys-popover";
import { codexAccountsPopoverCard } from "./codex-accounts-popover";
import { NAME_BY_ID, PROVIDERS_CHANGED_EVENT } from "./settings-tab";
import { sourceChartCard } from "./source-chart";
import { adminChartCard, ClaudeAdminSnapshot } from "./admin-chart";
import { currentLang, t } from "./i18n";
import { quotaSection, costBySection, configuredSection } from "./all-agents-sections";
import { InstalledAgent, visibleAgentIds } from "./settings-agents";
import {
  getPollSeconds, isManualRefresh, isRefreshOnOpenEnabled, effectiveQuotaWarn,
  isShowTrayPercentEnabled, getMonthlyBudgetUsd, MONTHLY_BUDGET_STORAGE_KEY,
  MONTHLY_BUDGET_CHANGED_EVENT, getProviderBudgetUsd, PROVIDER_BUDGET_STORAGE_KEYS,
  PROVIDER_BUDGET_CHANGED_EVENT, TRAY_DISPLAY_CHANGED_EVENT,
} from "./settings-about";
import { currentMonitor, getCurrentWindow } from "@tauri-apps/api/window";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { logoMark, logoUrl, providerTintCss } from "./logos";
import { mountSettingsWindow } from "./settings-window";
import { settingsIcon } from "./settings-icons";
import {
  ACTION_CENTER_RETRY_EVENT,
  ACTION_CENTER_SNAPSHOT_REQUEST_EVENT,
  ACTION_CENTER_UPDATED_EVENT,
  GUIDED_SETUP_STATUS_EVENT,
  collectActionCenterIssues,
  type ActionCenterIssue,
  type ActionCenterSnapshot,
  type GuidedSetupProviderInput,
} from "./action-center";
import { initTheme, setAppearance, resolveTheme } from "./theme";
import { checkWeeklyDigest } from "./weekly-digest";
import { fetchProjectInsightsReport, type ProjectInsightsReport } from "./insights-pane";

/** Popover width — matches macOS panelWidth / ProviderTabs density. */
const POPOVER_WIDTH = 420;
/** Last-resort cap when neither Tauri nor the DOM exposes screen bounds. */
const POPOVER_FALLBACK_MAX_HEIGHT = 640;
const POPOVER_MIN_HEIGHT = 220;
/** Keeps decorated window chrome just inside the monitor work area. */
const MONITOR_SAFETY_PX = 8;

const TAB_KEY = "birdnion.selectedTab";
/** How often the tick loop runs; each provider is only re-fetched once its
 * own effective interval (override or global) has elapsed — see
 * `dueProviderIds`. 10s gives per-provider overrides reasonable resolution
 * without the fixed-cost cadence of the global setting driving every tick. */
const TICK_MS = 10_000;

type ProviderCfg = {
  id: string; enabled?: boolean | null; refreshInterval?: number | null;
  showInTray?: boolean | null; displayName?: string | null;
  menuBarMetric?: string | null;
};
type Settings = { version: number; providers: ProviderCfg[] };

/** Footer luân phiên caption ↔ trạng thái nguồn, 5 giây một lượt (macOS parity). */
const FOOTER_ROTATE_MS = 5000;
let footerShowingSources = false;
let footerRotateTimer: number | null = null;

/** Local usage-report sources scanned from disk (Claude → Codex → Grok → OMP → Pi). */
const SCAN_SOURCES = ["claude", "codex", "grok", "omp", "pi", "kiro"] as const;
type ScanSource = (typeof SCAN_SOURCES)[number];

type State = {
  claude: UsageReport | null;
  codex: UsageReport | null;
  grok: UsageReport | null;
  omp: UsageReport | null;
  pi: UsageReport | null;
  kiro: UsageReport | null;
  statuses: ProviderStatus[];
  /** Agent phát hiện trên máy (`list_installed_agents`) — nguồn cho hàng "đã
   *  cấu hình" và cho visibility. Null khi chưa nạp xong. */
  agents: InstalledAgent[] | null;
  claudeAdmin: ClaudeAdminSnapshot | null;
  insights: ProjectInsightsReport | null;
  tab: string; // "all" | provider id
  refreshing: boolean;
  loadedOnce: boolean;
  /** Local-log scans still in flight — drives the All-tab scanning hint
   * (macOS AllUsageOverview "Scanning X, Y…"). */
  scanning: Set<ScanSource>;
};

const state: State = {
  claude: null,
  codex: null,
  grok: null,
  omp: null,
  pi: null,
  kiro: null,
  statuses: [],
  agents: null,
  claudeAdmin: null,
  insights: null,
  tab: (() => {
    const t0 = localStorage.getItem(TAB_KEY) || "all";
    return t0 === "settings" ? "all" : t0;
  })(),
  refreshing: false,
  loadedOnce: false,
  scanning: new Set<ScanSource>(),
};

let currentActionCenterIssues: ActionCenterIssue[] = [];
let actionCenterProjectionSeq = 0;
let actionCenterSnapshotReady = false;
let actionCenterSnapshotError = false;
let actionCenterSourceError = false;
let actionCenterProviders: GuidedSetupProviderInput[] = [];
let actionCenterInputSeq = 0;

declare global {
  interface Window {
    __BIRDNION_MODE__?: string;
  }
}

const isSettingsWindow = () => {
  // Prefer init-script flag set by Rust when creating the settings webview —
  // most reliable way to avoid mounting the popover/load/tick loop there.
  if (typeof window !== "undefined" && window.__BIRDNION_MODE__ === "settings") return true;
  try {
    if (getCurrentWindow().label === "settings") return true;
  } catch { /* browser / mock */ }
  return location.search.includes("settings=1") || location.hash === "#settings";
};

/** Prevent concurrent full reloads (focus + refresh + tick racing). */
let loadInFlight = false;
/** Ignore focus-triggered refresh for a short window after opening Settings. */
let suppressFocusRefreshUntil = 0;

function openSettings(
  section?: string,
  providerId?: string,
  remediationTarget?: ProviderRemediationTarget,
) {
  if (section) localStorage.setItem("birdnion.settingsSection", section);
  if (providerId) {
    localStorage.setItem("birdnion.selectedProvider", providerId);
  }
  if (remediationTarget) {
    localStorage.setItem("birdnion.providerRemediationTarget", remediationTarget);
  } else {
    localStorage.removeItem("birdnion.providerRemediationTarget");
  }
  // Opening Settings steals focus from main — don't immediately re-load main.
  suppressFocusRefreshUntil = Date.now() + 1500;
  void invoke("open_settings_window", { section: section ?? null }).catch((err) => {
    console.error("open_settings_window", err);
  });
}

/** Update only the header spinner/status without wiping the whole DOM. */
function paintRefreshChrome() {
  const btn = document.querySelector<HTMLButtonElement>(".header-refresh:not(.header-settings)");
  if (btn) {
    btn.classList.toggle("spinning", state.refreshing);
    btn.disabled = state.refreshing;
  }
  const pill = document.querySelector(".status-pill");
  const pillText = document.querySelector(".status-pill-text");
  if (pill) {
    pill.classList.toggle("updating", state.refreshing);
    pill.classList.toggle("ready", !state.refreshing);
  }
  if (pillText) {
    pillText.textContent = state.refreshing
      ? t("popoverUpdating")
      : state.loadedOnce ? t("popoverReady") : "…";
  }
}

/** Per-provider last-fetch timestamps (ms), used to honor `refreshInterval`
 * overrides independent of the global polling cadence. */
const lastFetched = new Map<string, number>();
/** Provider ids with a `provider_statuses` fetch currently in flight, shared
 * by EVERY fetch path — `load()`'s per-provider fanout, `refetchProvider()`,
 * and `tick()` — so a given provider is owned by exactly one caller at a
 * time regardless of which path started it. Added right before the request
 * fires, cleared in `finally` once it settles (success, error, or throw) so
 * an id can never get stuck "in flight" forever.
 *
 * Without this, three races were possible: `setInterval` re-invokes `tick()`
 * every `TICK_MS` regardless of whether the previous call resolved (and
 * `lastFetched` only updates once a fetch actually completes, so a slow
 * provider like Claude's ~160s cold CLI probe stayed "due" on every
 * overlapping tick); `refetchProvider()` had no guard at all against firing
 * for a provider `load()` or `tick()` was already fetching; and any two of
 * those overlapping requests for the same provider could resolve out of
 * order, letting a stale completion clobber a fresher one. */
const inFlightProviderIds = new Set<string>();

/** Pure filter: which of `dueIds` are actually fetchable right now, i.e. not
 * already in flight from ANY caller (`load`, `refetchProvider`, or an
 * earlier still-unresolved `tick`) — see `inFlightProviderIds`. Kept
 * separate from `dueProviderIds` (which awaits `get_settings`) so this one
 * decision is a plain function of its inputs — easy to audit/exercise even
 * without a JS test runner wired up in this project. */
export function eligibleForFetch(dueIds: string[], inFlight: ReadonlySet<string>): string[] {
  return dueIds.filter((id) => !inFlight.has(id));
}

/** Shared per-provider ownership guard for the two single-id fetch paths
 * (`load()`'s fanout and `refetchProvider()`). If `id` is already in
 * `inFlightProviderIds` (from `load`, `refetchProvider`, or `tick`), this is
 * a no-op — "don't create a duplicate request", matching the manual-retry
 * UX: clicking Retry while a fetch for that provider is already in flight
 * simply doesn't start a second one; the in-flight request's own caller
 * still applies its result. Otherwise claims `id` for the duration of
 * `fetchAndApply` and always releases it in `finally`, so an IPC error or
 * thrown exception can never leave the id stuck. */
async function withProviderInFlightGuard(id: string, fetchAndApply: () => Promise<void>): Promise<void> {
  if (inFlightProviderIds.has(id)) return;
  inFlightProviderIds.add(id);
  try {
    await fetchAndApply();
  } finally {
    inFlightProviderIds.delete(id);
  }
}
/** Consecutive awaited failures per provider. The existing 10-second tick
 * remains the only timer; this state only stretches each failed provider's
 * own due interval so healthy providers keep their configured cadence. */
const adaptiveFailureStreaks = new Map<string, number>();

function adaptiveBackoffMultiplier(consecutiveFailures: number): number {
  const failures = Math.max(0, Math.trunc(consecutiveFailures));
  if (failures <= 1) return 1;
  if (failures === 2) return 2;
  if (failures === 3) return 4;
  return 8;
}

function adaptiveIntervalMs(baseMs: number, providerId: string): number {
  if (baseMs <= 0) return baseMs;
  return baseMs * adaptiveBackoffMultiplier(adaptiveFailureStreaks.get(providerId) ?? 0);
}

/** Record every attempted id, including an IPC result that omitted a status.
 * Manual/open/account-switch retries start a new streak and always bypass the
 * due gate; a failed user retry therefore becomes failure #1 rather than
 * inheriting an old automatic backoff. */
function recordFetchOutcomes(
  requestedIds: string[],
  fresh: ProviderStatus[],
  manual: boolean,
): void {
  const byId = new Map(fresh.map((status) => [status.id, status]));
  const now = Date.now();
  for (const id of requestedIds) {
    lastFetched.set(id, now);
    const status = byId.get(id);
    if (status && !status.error) {
      adaptiveFailureStreaks.delete(id);
      continue;
    }
    const previous = manual ? 0 : (adaptiveFailureStreaks.get(id) ?? 0);
    adaptiveFailureStreaks.set(id, previous + 1);
  }
}

/** Provider ids due for a fetch this tick: providers whose own
 * `refreshInterval` (or the global interval when unset/0) has elapsed since
 * their last fetch. Mirrors macOS `QuotaService.effectiveInterval`. Returns
 * `[]` when the global interval is in manual mode (0) — manual mode disables
 * ALL background auto-fetching regardless of per-provider overrides,
 * mirroring macOS `RefreshFrequency.manual`. */
async function dueProviderIds(): Promise<string[] | undefined> {
  if (isManualRefresh()) return [];
  const settings = await invoke<Settings>("get_settings").catch(() => null);
  if (!settings) return undefined;
  const globalMs = getPollSeconds() * 1000;
  const now = Date.now();
  const due: string[] = [];
  for (const p of settings.providers) {
    if (p.enabled !== true) continue;
    const baseMs = p.refreshInterval && p.refreshInterval > 0 ? p.refreshInterval * 1000 : globalMs;
    const intervalMs = adaptiveIntervalMs(baseMs, p.id);
    const last = lastFetched.get(p.id);
    if (last === undefined || now - last >= intervalMs) due.push(p.id);
  }
  return due;
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function goTab(id: string) {
  // KHÔNG đóng panel phụ ở đây: macOS chỉ đóng khi đổi kỳ (và chỉ panel ngày)
  // hoặc khi bấm ✕ — đổi tab provider để panel nguyên trạng.
  state.tab = id;
  localStorage.setItem(TAB_KEY, id);
  render();
}

/** macOS BirdNionHeader parity: brand mark + status + refresh + appearance. */
function appHeader(): HTMLElement {
  const head = el("header", "app-header");
  const brand = el("div", "app-brand");
  const icon = el("span", "app-logo");
  icon.setAttribute("role", "img");
  icon.setAttribute("aria-label", "BirdNion");
  brand.append(icon);

  // Status pill (ready / updating)
  const refreshing = state.refreshing;
  const pill = el("div", `status-pill${refreshing ? " updating" : " ready"}`);
  pill.append(el("span", "status-pill-dot"));
  pill.append(el("span", "status-pill-text",
    refreshing ? t("popoverUpdating")
      : state.loadedOnce ? t("popoverReady") : "…"));
  brand.append(pill);

  const actions = el("div", "header-actions");
  const actionCenter = actionCenterHeaderButton();
  const refresh = document.createElement("button");
  refresh.type = "button";
  refresh.className = `header-refresh${refreshing ? " spinning" : ""}`;
  refresh.title = t("popoverRefresh");
  refresh.setAttribute("aria-label", t("popoverRefresh"));
  refresh.disabled = refreshing;
  refresh.append(settingsIcon("arrow.clockwise", "header-refresh-icon"));
  refresh.addEventListener("click", () => { void refreshNow(); });

  // macOS BirdNionHeader: sun/moon toggles light ↔ dark (resolved theme).
  // Icon shows the *target* mode (sun → go light, moon → go dark).
  const effectivelyDark = resolveTheme() === "dark";
  const appearanceIcon = effectivelyDark ? "sun.max" : "moon";
  const themeBtn = document.createElement("button");
  themeBtn.type = "button";
  themeBtn.className = "header-refresh header-appearance";
  themeBtn.title = effectivelyDark ? t("appearanceLight") : t("appearanceDark");
  themeBtn.setAttribute("aria-label", themeBtn.title);
  themeBtn.append(settingsIcon(appearanceIcon, "header-refresh-icon"));
  themeBtn.addEventListener("click", () => {
    setAppearance(resolveTheme() === "dark" ? "light" : "dark");
    render();
  });

  if (actionCenter) actions.append(actionCenter);
  actions.append(refresh, themeBtn);
  head.append(brand, actions);
  return head;
}

function actionCenterHeaderButton(): HTMLButtonElement | null {
  if (currentActionCenterIssues.length === 0) return null;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "header-refresh header-action-center";
  button.title = t("actionCenterOpen");
  button.setAttribute("aria-label", t("actionCenterOpen"));
  button.append(settingsIcon("exclamationmark.circle", "header-refresh-icon"));
  button.append(el("span", "header-action-count", String(currentActionCenterIssues.length)));
  button.addEventListener("click", () => openSettings("actionCenter"));
  return button;
}

function updateActionCenterHeaderBadge() {
  const actions = document.querySelector<HTMLElement>(".header-actions");
  if (!actions) return;
  actions.querySelector(".header-action-center")?.remove();
  const button = actionCenterHeaderButton();
  if (button) actions.prepend(button);
}

async function refreshActionCenterIssues() {
  const seq = ++actionCenterProjectionSeq;
  let issues: ActionCenterIssue[];
  try {
    issues = await collectActionCenterIssues(
      state.statuses,
      staleWarningFor,
      actionCenterProviders,
    );
  } catch {
    actionCenterSnapshotError = true;
    const snapshot: ActionCenterSnapshot = {
      issues: currentActionCenterIssues,
      ready: false,
      error: true,
    };
    await emit(ACTION_CENTER_UPDATED_EVENT, snapshot).catch(() => {});
    return;
  }
  if (seq !== actionCenterProjectionSeq) return;
  currentActionCenterIssues = issues;
  actionCenterSnapshotError = actionCenterSourceError;
  actionCenterSnapshotReady = state.loadedOnce
    && actionCenterProviders.every((provider) => provider.detectionReady !== undefined)
    && !state.statuses.some((status) => status.pending
      && ["claude", "codex", "grok"].includes(status.id));
  updateActionCenterHeaderBadge();
  const snapshot: ActionCenterSnapshot = {
    issues,
    ready: actionCenterSnapshotReady,
    error: actionCenterSnapshotError,
  };
  await emit(ACTION_CENTER_UPDATED_EVENT, snapshot).catch(() => {});
}

async function rebuildActionCenterInputs(settings: Settings | null) {
  const seq = ++actionCenterInputSeq;
  const ids = settings?.providers
    .filter((provider) => provider.enabled === true
      && ["claude", "codex", "grok"].includes(provider.id))
    .map((provider) => provider.id) ?? [];
  const inputs: GuidedSetupProviderInput[] = ids.map((id) => ({
    id,
    name: NAME_BY_ID.get(id) ?? id,
    enabled: true,
  }));
  actionCenterProviders = inputs;
  let detectionFailed = false;
  await Promise.all(inputs.map(async (provider) => {
    const detection = await invoke<{ isReady: boolean }>("provider_onboarding_detection", {
      id: provider.id,
    }).catch(() => null);
    if (detection) provider.detectionReady = detection.isReady;
    else detectionFailed = true;
  }));
  if (seq !== actionCenterInputSeq) return;
  actionCenterSourceError = settings === null || detectionFailed;
  await refreshActionCenterIssues();
}

/**
 * Icon-only provider chips — macOS `ProviderTabs` parity:
 * All + providers only (dividers between chips). No VI / gear in the strip —
 * language lives in Settings → General; Settings opens from the footer.
 * Logos are monochrome: secondary when idle, blue when active.
 */
function tabsStrip(): HTMLElement {
  const strip = el("nav", "tabs tabs-pills");

  const addIconTab = (id: string, label: string, mark: Element, cornerTint?: string) => {
    const active = state.tab === id;
    // Design: logo-only squares for every provider (selected = ink fill).
    const tab = el("button", active ? "tab tab-pill tab-icon active" : "tab tab-pill tab-icon");
    tab.title = label;
    tab.setAttribute("aria-label", label);
    tab.append(mark);
    // Design corner mark: 5×5 at top-right (CSS top/right -1px).
    if (!active && cornerTint) {
      const corner = el("span", "tab-corner-mark");
      corner.style.background = cornerTint;
      tab.append(corner);
    }
    tab.addEventListener("click", () => goTab(id));
    strip.append(tab);
  };

  // Design: All = icon-only grid square.
  {
    const allActive = state.tab === "all";
    const allTab = el("button", allActive ? "tab tab-pill tab-icon active" : "tab tab-pill tab-icon");
    allTab.title = t("tabAll");
    allTab.setAttribute("aria-label", t("tabAll"));
    allTab.append(settingsIcon("square.grid.2x2", allActive ? "tab-sf-icon" : "tab-sf-icon"));
    if (allActive) allTab.classList.add("active");
    allTab.addEventListener("click", () => goTab("all"));
    strip.append(allTab);
  }

  for (const s of state.statuses) {
    const active = state.tab === s.id;
    const mark = logoMark(s.id, active ? "tab-logo-mono tab-logo-on-accent" : "tab-logo-mono");
    const tint = providerTintCss(s.id);
    if (!active && tint) {
      // Brand tint on idle chips (macOS providerTint); falls back to secondary.
      mark.style.setProperty("--tab-tint", tint);
    }
    addIconTab(s.id, s.displayName, mark, active ? undefined : (tint ?? undefined));
  }

  return strip;
}

/** Nguồn chi phí đủ điều kiện lên footer: có tab hiển thị và scan đã tính vào
 *  tổng (parity macOS `footerSourceStates`). */
function footerSourceStates(): { id: ScanSource; live: boolean; scannedAt: number | null }[] {
  const out: { id: ScanSource; live: boolean; scannedAt: number | null }[] = [];
  for (const id of SCAN_SOURCES) {
    if (!state.statuses.some((s) => s.id === id)) continue;
    const report = state[id];
    if (!report?.included) continue;
    out.push({ id, live: report.live === true, scannedAt: report.scannedAt ?? null });
  }
  return out;
}

/** Dòng trạng thái nguồn: logo tint + LIVE/LỊCH SỬ + độ tươi của lần quét. */
function footerSourceRow(
  sources: { id: ScanSource; live: boolean; scannedAt: number | null }[],
): HTMLElement {
  const row = el("div", "footer-sources");
  for (const source of sources) {
    const item = el("span", "footer-source");
    const mark = logoMark(source.id, "tab-logo-mono footer-source-logo");
    const tint = providerTintCss(source.id);
    if (tint) mark.style.setProperty("--tab-tint", tint);
    item.append(mark);
    item.append(el("span", `footer-source-state ${source.live ? "is-live" : "is-history"}`,
      source.live ? t("confidence.state.live") : t("confidence.state.history")));
    const fresh = scanFreshness(source.scannedAt);
    if (fresh) item.append(el("span", "footer-source-fresh", `· ${fresh.toUpperCase()}`));
    row.append(item);
  }
  return row;
}

/** Footer: "CẬP NHẬT …" left + icon buttons Settings / About / Quit (macOS parity).
 *  Ô bên trái luân phiên 5 giây giữa caption cập nhật và trạng thái nguồn. */
function popoverFooter(): HTMLElement {
  const foot = el("footer", "popover-footer footer-compact");

  let latest = 0;
  for (const s of state.statuses) {
    if (s.lastUpdated && s.lastUpdated > latest) latest = s.lastUpdated;
  }
  const caption = latest > 0 ? relativeTime(latest) : null;
  const slot = el("div", "footer-rotate-slot");
  const sources = footerSourceStates();

  const paintSlot = () => {
    slot.textContent = "";
    if (footerShowingSources && sources.length > 0) {
      slot.append(footerSourceRow(sources));
    } else if (caption) {
      slot.append(el("span", "footer-updated", t("lastUpdated", { time: caption })));
    }
  };
  paintSlot();
  foot.append(slot);

  if (footerRotateTimer != null) clearInterval(footerRotateTimer);
  if (sources.length > 0) {
    footerRotateTimer = window.setInterval(() => {
      // Slot cao cố định trong CSS nên đổi nội dung không làm popover đổi cỡ.
      if (!slot.isConnected) {
        if (footerRotateTimer != null) clearInterval(footerRotateTimer);
        footerRotateTimer = null;
        return;
      }
      footerShowingSources = !footerShowingSources;
      paintSlot();
    }, FOOTER_ROTATE_MS);
  } else {
    footerRotateTimer = null;
    footerShowingSources = false;
  }

  const actions = el("div", "footer-actions");
  const mkIcon = (sf: Parameters<typeof settingsIcon>[0], label: string, extraClass: string, onClick: () => void) => {
    const btn = el("button", `footer-icon-btn${extraClass ? ` ${extraClass}` : ""}`);
    btn.title = label;
    btn.setAttribute("aria-label", label);
    btn.append(settingsIcon(sf, "footer-icon-svg"));
    btn.addEventListener("click", onClick);
    return btn;
  };
  actions.append(
    mkIcon("gearshape", t("footerSettings"), "", () => openSettings("general")),
    mkIcon("info.circle", t("footerAbout"), "", () => openSettings("about")),
    mkIcon("power", t("footerQuit"), "quit", () => {
      void invoke("quit_app").catch(() => { window.close(); });
    }),
  );
  foot.append(actions);
  return foot;
}

/** Relative "vừa cập nhật" / "N phút trước" from unix seconds or ms. */
function relativeTime(ts: number): string | null {
  if (!Number.isFinite(ts) || ts <= 0) return null;
  const ms = ts > 1e12 ? ts : ts * 1000;
  if (Number.isNaN(new Date(ms).getTime())) return null;
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (seconds < 5) return t("time.justUpdated");
  if (seconds < 60) return t("time.secondsAgo", { n: seconds });
  if (seconds < 3600) return t("time.minutesAgo", { n: Math.floor(seconds / 60) });
  return t("time.hoursAgo", { n: Math.floor(seconds / 3600) });
}

/** Sources whose scan is in flight AND that have no report yet — macOS
 * AllUsageOverview `pendingSources` (a rescan keeps the old report visible,
 * so it never counts as pending). */
/** Agent phát hiện được nhưng không có quota lẫn log chi phí — dòng gộp
 *  "ĐÃ CẤU HÌNH" ở tab All (parity macOS `configuredRows`). */
function configuredAgents(): InstalledAgent[] {
  const all = state.agents;
  if (!all) return [];
  const visible = new Set(visibleAgentIds(all));
  // Chỉ agent KHÔNG quota và KHÔNG log chi phí mới thuộc hàng gộp này; ẩn
  // agent trong Settings chỉ giấu nó khỏi đây, tổng chi phí giữ nguyên.
  return all.filter((agent) =>
    visible.has(agent.id) && !agent.hasQuota && !agent.hasCost);
}

/** Số nguồn chi phí thật sự được tính vào tổng — hiện sau token ở hero
 *  ("20.3B tokens · 6 agent"), parity macOS `CombinedUsageReport
 *  .includedSourceCount`. */
function includedSourceCount(): number {
  return SCAN_SOURCES.filter((id) => state[id]?.included === true).length;
}

function pendingScanSources(): ScanSource[] {
  return SCAN_SOURCES.filter((s) => state.scanning.has(s) && !state[s]);
}

/** "Đang quét Claude, Codex…" hint while some scans are still in flight but
 * others already rendered — macOS AllUsageOverview partial-results hint. */
function scanningHint(names: ScanSource[]): HTMLElement {
  const labels = names.map((s) => NAME_BY_ID.get(s) ?? s);
  return el("div", "scanning-hint", t("scanningSources", { names: labels.join(", ") }));
}

/**
 * Natural content height of the popover chrome + body + footer.
 * Sums sections so we don't under-count flex/gap/padding edge cases that
 * leave "Thoát BirdNion" half-clipped.
 */
function measurePopoverContentHeight(app: HTMLElement): number {
  app.style.height = "auto";
  void app.offsetHeight;

  const header = app.querySelector(".app-header") as HTMLElement | null;
  const tabs = app.querySelector(".tabs") as HTMLElement | null;
  const body = app.querySelector(".app-body") as HTMLElement | null;
  const footer = app.querySelector(".popover-footer") as HTMLElement | null;

  // Instrument redesign: `.container { padding: 0; gap: 0 }` — section
  // padding lives inside header/tabs/body/footer themselves. The pre-redesign
  // padY (8+10) + three 7px gaps inflated the window by ~39px and left a
  // blank band above the footer on short tabs (e.g. Codex Accounts row).
  const style = getComputedStyle(app);
  const padY =
    (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  const gap = parseFloat(style.rowGap || style.gap) || 0;
  const sections = [header, tabs, body, footer].filter(
    (el): el is HTMLElement => el != null,
  );
  const gaps = gap * Math.max(0, sections.length - 1);
  let sum = padY + gaps;
  for (const el of sections) {
    // scrollHeight catches overflow children; rect is laid-out size.
    sum += Math.max(el.scrollHeight, el.getBoundingClientRect().height);
  }

  const whole = Math.max(app.scrollHeight, app.getBoundingClientRect().height);
  return Math.max(sum, whole);
}

/**
 * Resize the main popover to hug its content (macOS DropdownPanel fittingSize).
 *
 * No internal scrollbar on normal tabs. Tauri `setSize` accepts the inner
 * window size; outer−inner chrome is used only to derive the monitor limit.
 */
async function fitMainWindowToContent() {
  if (isSettingsWindow()) return;
  const app = document.querySelector("#app") as HTMLElement | null;
  if (!app) return;

  document.documentElement.classList.remove("popover-capped");
  document.body.classList.remove("popover-capped");

  const natural = measurePopoverContentHeight(app);
  if (natural < 80) return;

  const contentH = Math.ceil(natural);
  const win = getCurrentWindow();

  // Outer and inner sizes are physical; convert their difference to logical px.
  let chromeLogical = 0;
  try {
    const scale = await win.scaleFactor();
    const outer = await win.outerSize();
    const inner = await win.innerSize();
    if (outer.height > 0 && inner.height > 0 && outer.height >= inner.height) {
      chromeLogical = (outer.height - inner.height) / scale;
    }
  } catch {
    // Browser/mock: no native window chrome to account for.
  }

  let availableOuterHeight: number | null = null;
  try {
    const monitor = await currentMonitor();
    if (monitor) {
      availableOuterHeight = monitor.workArea.size.toLogical(monitor.scaleFactor).height;
    }
  } catch {
    // Browser/mock: fall through to the DOM screen bounds.
  }
  if (!(availableOuterHeight && availableOuterHeight > 0)) {
    const domAvailable = window.screen?.availHeight;
    availableOuterHeight = typeof domAvailable === "number" && domAvailable > 0
      ? domAvailable
      : null;
  }

  const maxInner = availableOuterHeight === null
    ? POPOVER_FALLBACK_MAX_HEIGHT
    : Math.max(1, Math.floor(availableOuterHeight - MONITOR_SAFETY_PX - chromeLogical));
  const targetInner = Math.min(
    maxInner,
    Math.max(POPOVER_MIN_HEIGHT, contentH),
  );

  try {
    await win.setSize(new LogicalSize(POPOVER_WIDTH, targetInner));
  } catch {
    // Browser/mock
  }

  // Second / third pass: grow until footer is fully inside the inner viewport.
  // (Title-bar chrome can differ after the first resize on retina.)
  for (let pass = 0; pass < 3; pass++) {
    await new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r())));
    const footer = app.querySelector(".popover-footer") as HTMLElement | null;
    if (!footer) break;
    const clip = footer.getBoundingClientRect().bottom - window.innerHeight;
    if (clip <= 0.5) break;
    try {
      const scale = await win.scaleFactor();
      const inner = (await win.innerSize()).toLogical(scale);
      const nextHeight = Math.min(maxInner, Math.ceil(inner.height + clip + 6));
      if (nextHeight <= inner.height) break;
      await win.setSize(new LogicalSize(inner.width, nextHeight));
    } catch {
      break;
    }
  }

  app.style.height = "";
  // Scroll only when the natural content truly exceeds the available inner area.
  const capped = contentH > maxInner;
  document.documentElement.classList.toggle("popover-capped", capped);
  document.body.classList.toggle("popover-capped", capped);
}

let fitWindowInFlight = false;
let fitWindowPending = false;

function waitForPopoverLayout(): Promise<void> {
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  });
}

/** Serialize fits so only the newest DOM state can write the final window size. */
async function runPendingWindowFits() {
  if (fitWindowInFlight) return;
  fitWindowInFlight = true;
  try {
    while (fitWindowPending) {
      fitWindowPending = false;
      await waitForPopoverLayout();
      await fitMainWindowToContent();
    }
  } finally {
    fitWindowInFlight = false;
    if (fitWindowPending) void runPendingWindowFits();
  }
}

function scheduleFitWindow() {
  if (isSettingsWindow()) return;
  // Logos may load late; their re-fit joins the same coalesced queue.
  document.querySelectorAll("#app img").forEach((node) => {
    const img = node as HTMLImageElement;
    if (!img.complete) {
      img.addEventListener("load", scheduleFitWindow, { once: true });
    }
  });
  fitWindowPending = true;
  if (!fitWindowInFlight) void runPendingWindowFits();
}

function render() {
  const app = document.querySelector("#app")!;
  app.textContent = "";
  // Fall back to All when the remembered provider tab disappeared — but only
  // once statuses are real; early paints during load have an empty/partial
  // list and must not clobber the remembered tab.
  if (state.tab !== "all" && state.statuses.length > 0
    && !state.statuses.some((s) => s.id === state.tab)) {
    state.tab = "all";
  }
  app.append(appHeader());
  app.append(tabsStrip());

  const body = el("div", "app-body");
  app.append(body);

  if (state.loadedOnce && state.statuses.length === 0) {
    const connect = el("section", "card first-provider-cta");
    connect.append(
      el("div", "first-provider-title", currentLang() === "vi" ? "Kết nối provider đầu tiên" : "Connect your first provider"),
      el("div", "first-provider-body", currentLang() === "vi"
        ? "Phát hiện nguồn đăng nhập, chạy kiểm tra thật và hiển thị quota live."
        : "Detect a sign-in source, run a real test, and show live quota."),
    );
    const button = el("button", "save-button", currentLang() === "vi" ? "Kết nối provider" : "Connect provider");
    button.addEventListener("click", () => openSettings("providers", "claude"));
    connect.append(button);
    body.append(connect);
  }

  if (state.tab === "all") {
    const pending = pendingScanSources();
    if (!state.claude && !state.codex && !state.grok && !state.omp && !state.pi) {
      // No data yet: skeleton card while scans are in flight (macOS
      // AllUsageOverview), "no logs" only once every scan came back empty.
      if (pending.length > 0) {
        const card = el("section", "card");
        card.append(loadingSkeleton());
        body.append(card);
      } else {
        body.append(el("div", "empty", t("noLogs")));
      }
    } else {
      if (pending.length > 0) body.append(scanningHint(pending));
      const combined = combine(state.claude, state.codex, state.grok, state.omp, state.pi, state.kiro);
      // Agent-centric order (macOS parity 2026-08-24): tổng chi phí →
      // quota → chi phí theo → đã cấu hình → ngân sách.
      // Heatmap và insights card cố tình KHÔNG nằm ở All nữa: nhịp hoạt động
      // xem trong Settings → Phân tích. Badge LIVE/LỊCH SỬ cũng không nằm ở
      // đây nữa — footer luân phiên đã mang thông tin đó (macOS parity).
      body.append(chartCard(
        combined, state.claude?.hourly ?? [], includedSourceCount()));
      const visibleAgents = state.agents
        ? state.agents.filter((a) => visibleAgentIds(state.agents!).includes(a.id))
        : null;
      const quota = quotaSection(
        state.statuses, combined.daily, visibleAgents, visibleAgents?.length ?? 0);
      if (quota) body.append(quota);
      const costBy = costBySection(combined, allChartDays(), render);
      if (costBy) body.append(costBy);
      const configured = configuredSection(configuredAgents());
      if (configured) body.append(configured);
      const budget = budgetForecastCard(combined, getMonthlyBudgetUsd());
      if (budget) body.append(budget);
    }
  } else {
    const status = state.statuses.find((s) => s.id === state.tab);
    if (status) {
      body.append(providerCard(
        status,
        () => { void refetchProvider(status.id); },
        (target) => openSettings("providers", status.id, target),
        staleWarningFor(status.id),
      ));
      void claudeCodeQuickApplyCard(status, () => openSettings("claudeCode"))
        .then((card) => {
          // Insert after the full provider stack (header + body cards).
          const stack = body.querySelector(".provider-stack");
          if (card && stack) stack.after(card);
          else if (card) body.append(card);
          scheduleFitWindow();
        });
    }
    // FreeModel: quick account switcher (browser sessions + pasted cookies)
    // — popover parity with macOS CodexAccountsPopoverSection.
    if (state.tab === "freemodel") {
      body.append(freemodelAccountsPopoverCard(
        () => scheduleFitWindow(),
        () => { void refetchProvider("freemodel"); },
      ));
    }
    if (state.tab === "elevenlabs") {
      body.append(elevenlabsKeysPopoverCard(
        () => scheduleFitWindow(),
        () => { void refetchProvider("elevenlabs"); },
      ));
    }
    // Claude/Codex/Grok tabs also show their own local 30-day cost chart,
    // matching the macOS per-provider chart cards.
    if (state.tab === "claude" && state.claude) {
      body.append(sourceChartCard(state.claude, "claude"));
      if (state.claudeAdmin) body.append(adminChartCard(state.claudeAdmin));
    } else if (state.tab === "codex" && state.codex) {
      body.append(sourceChartCard(state.codex, "codex"));
    } else if (state.tab === "grok" && state.grok) {
      body.append(sourceChartCard(state.grok, "grok"));
    }
    // Per-provider monthly budget — only when THIS tab's own budget is
    // configured (macOS ProviderBudgetCard parity). `combine()` is scoped to
    // just this source (other two passed `null`) so `monthlyForecast` never
    // mixes in another provider's spend. Renders even before the scan lands
    // (report null → scanConfidence "unavailable" → "no cost data" row).
    if (state.tab === "claude" || state.tab === "codex" || state.tab === "grok"
        || state.tab === "kiro") {
      const sourceId = state.tab as UsageSourceId;
      const sourceReport = state[sourceId];
      const sourceCombined = combine(
        sourceId === "claude" ? sourceReport : null,
        sourceId === "codex" ? sourceReport : null,
        sourceId === "grok" ? sourceReport : null,
        null,
        null,
        sourceId === "kiro" ? sourceReport : null,
      );
      const providerBudget = providerBudgetCard(
        sourceId, NAME_BY_ID.get(sourceId) ?? sourceId, sourceReport, sourceCombined,
        getProviderBudgetUsd(sourceId));
      if (providerBudget) body.append(providerBudget);
    }
    // Codex: account switcher BELOW the cost chart (macOS CodexAccountsPopoverSection).
    if (state.tab === "codex") {
      body.append(codexAccountsPopoverCard(
        () => scheduleFitWindow(),
        () => { void refetchProvider("codex"); },
      ));
    }

    // Status page row — last provider-local content (macOS ServiceStatusStrip).
    if (status) {
      const strip = serviceStatusStrip(status);
      if (strip) body.append(strip);
    }
  }
  app.append(popoverFooter());
  scheduleFitWindow();
}

/** Fire an OS notification once per threshold crossing — macOS QuotaNotifier
 * parity: per-provider/per-window thresholds (Settings → Cảnh báo quota)
 * falling back to the global L1 (warn) / L2 (critical) pair; each level
 * re-arms once remaining climbs 5 points above it. */
const warned = new Set<string>();
function checkQuotaWarnings(statuses: ProviderStatus[]) {
  for (const s of statuses) {
    for (const w of s.windows) {
      const th = effectiveQuotaWarn(s.id, w.label);
      // Most severe level first; at most one notification per pass.
      const levels: [string, number][] = [["critical", th.critical], ["warn", th.warn]];
      let notified = false;
      for (const [level, pct] of levels) {
        const key = `${s.id}:${w.label}:${level}`;
        if (w.remainingPct <= pct) {
          if (!warned.has(key) && !notified) {
            warned.add(key);
            notified = true;
            void invoke("notify", {
              title: `BirdNion — ${s.displayName}`,
              body: `${w.label}: còn ${w.remainingPct}% quota.`,
            }).catch(() => {});
          }
        } else if (w.remainingPct > pct + 5) {
          warned.delete(key);
        }
      }
    }
  }
}

/** Dedicated flag, default ON — reliability alerts must work out of the box
 * and are NOT coupled to the quota-warning path above. */
const FAILURE_NOTIFY_KEY = "providerFailureNotificationsEnabled";
function failureNotificationsEnabled(): boolean {
  return localStorage.getItem(FAILURE_NOTIFY_KEY) !== "false";
}

/** Per-provider failure-episode state, SEPARATE from `warned` — port of
 * macOS `QuotaService.evaluateFailureEpisode`. `consecutive` counts
 * consecutive failing FETCHES (only providers actually fetched this tick
 * are evaluated); `notified` prevents re-notifying within one episode. */
const failureEpisode = new Map<string, { consecutive: number; notified: boolean }>();
const FAILURE_NOTIFY_THRESHOLD = 3;

/** Called once per FETCHED provider per poll with the awaited fetch result.
 * Fires exactly one notification at the Nth consecutive failure, stays
 * silent while the episode continues, and re-arms on recovery (a fresh
 * episode notifies again). */
function evaluateFailureEpisodes(fetched: ProviderStatus[]) {
  for (const s of fetched) {
    const st = failureEpisode.get(s.id) ?? { consecutive: 0, notified: false };
    if (!s.error) {
      failureEpisode.set(s.id, { consecutive: 0, notified: false });
      continue;
    }
    st.consecutive += 1;
    if (st.consecutive >= FAILURE_NOTIFY_THRESHOLD && !st.notified && failureNotificationsEnabled()) {
      st.notified = true;
      void classifyAndNotifyFailure(s);
    }
    failureEpisode.set(s.id, st);
  }
}

async function classifyAndNotifyFailure(s: ProviderStatus) {
  const suffix = (await invoke<string | null>("classify_provider_error", { raw: s.error }).catch(() => null)) ?? "unknown";
  await invoke("notify", {
    title: s.displayName,
    body: `${t(`providerError.${suffix}.title`)} — ${t(`providerError.${suffix}.hint`)}`,
  }).catch(() => {});
}

/**
 * One rotating tray frame — macOS `MenuBarIconRenderer.Frame.provider` parity.
 * Visual: **`91%` then provider logo** (composite PNG; title left empty so
 * tray-icon's image-left layout cannot reverse the order).
 */
type TrayFrame = {
  providerId: string;
  /** Percent text only, e.g. "91%" or "93%  82%" (macOS percentTitle). */
  percentText: string;
  tooltipPart: string;
  /** Composite PNG: percent text + provider logo (white-tinted). */
  iconPng: number[] | null;
};

/** How long each provider frame stays on the tray before advancing (macOS = 5s). */
const TRAY_FRAME_MS = 5_000;
let trayFrames: TrayFrame[] = [];
let trayFrameIndex = 0;
let trayRotationTimer: ReturnType<typeof setInterval> | null = null;
/** Cache composite icons: `${providerId}|${percentText}` → PNG bytes. */
const trayIconCache = new Map<string, number[]>();

function clampPct(n: number): number {
  return Math.max(0, Math.min(100, Math.round(n)));
}

/** macOS `MenuBarIconRenderer.percentTitle` — digits only, no provider name. */
function trayPercentText(s: ProviderStatus): string {
  return resolveTrayMetric(s, null)
    .map((p: number) => `${clampPct(p)}%`)
    .join("  ");
}

/** Pure resolver for tray metric preference.
 * Mirrors macOS `MenuBarIconRenderer.resolveTrayMetric`.
 * Does NOT mutate `s.windows`; operates on copied array.
 * Antigravity and FreeModel keep their special semantics. */
function resolveTrayMetric(s: ProviderStatus, metricPref: string | null | undefined): number[] {
  if (s.id === "antigravity") {
    const labels = new Set([
      "Gemini 5-hour",
      "Gemini weekly",
      "Claude/GPT 5-hour",
      "Claude/GPT weekly",
    ]);
    const semantic = s.windows.filter((w) => labels.has(w.label));
    const representative = (candidates: typeof semantic) => {
      let selected = candidates[0];
      for (const candidate of candidates.slice(1)) {
        if (!selected || candidate.usedPct > selected.usedPct) {
          selected = candidate;
          continue;
        }
        if (candidate.usedPct === selected.usedPct) {
          const candidateFiveHour = candidate.label.endsWith("5-hour");
          const selectedFiveHour = selected.label.endsWith("5-hour");
          if (candidateFiveHour && !selectedFiveHour) selected = candidate;
        }
      }
      return selected;
    };
    const gemini = semantic.filter((w) => w.label.startsWith("Gemini "));
    const claudeGpt = semantic.filter((w) => w.label.startsWith("Claude/GPT "));
    const selected = representative(gemini) ?? representative(claudeGpt);
    return selected ? [clampPct(selected.remainingPct)] : [];
  }
  if (s.id === "freemodel") {
    const balance = s.windows.find((w) => w.label === "Số dư");
    const fiveH = s.windows.find((w) => w.label === "5 giờ");
    if (fiveH && fiveH.remainingPct <= 0 && balance && balance.remainingPct > 0) {
      return [balance.remainingPct];
    }
    const out = s.windows.filter((w) => w.label !== "Số dư").map((w) => w.remainingPct);
    if (out.length === 0 && balance) return [balance.remainingPct];
    return out;
  }

  // Generic providers: resolve metric preference
  // If no preference or "automatic", use default usable-first logic
  if (!metricPref || metricPref === "automatic") {
    const primaryWindows = s.windows.filter(w => w.label !== "Số dư" && !/bonus|balance/i.test(w.label));
    const candidates = primaryWindows.length > 0 ? primaryWindows : s.windows;
    if (candidates.length === 0) return [];
    // Copy array before sorting to avoid mutation
    const sorted = [...candidates].sort((a, b) => {
      const aExhausted = a.remainingPct <= 0;
      const bExhausted = b.remainingPct <= 0;
      if (aExhausted !== bExhausted) return aExhausted ? -1 : 1;
      return (b.usedPct ?? 0) - (a.usedPct ?? 0);
    });
    return [clampPct(sorted[0].remainingPct)];
  }

  // Apply metric preference: primary, secondary, primaryAndSecondary, tertiary, extraUsage, average, monthlyPlan
  const windows = s.windows.filter(w => w.label !== "Số dư" && !/bonus|balance/i.test(w.label));
  if (windows.length === 0) return [];

  switch (metricPref) {
    case "primary":
      return [clampPct(windows[0].remainingPct)];
    case "secondary":
      return windows.length > 1 ? [clampPct(windows[1].remainingPct)] : [clampPct(windows[0].remainingPct)];
    case "primaryAndSecondary":
      if (windows.length > 1) {
        return [clampPct(windows[0].remainingPct), clampPct(windows[1].remainingPct)];
      }
      return [clampPct(windows[0].remainingPct)];
    case "tertiary":
      return windows.length > 2 ? [clampPct(windows[2].remainingPct)] : [clampPct(windows[0].remainingPct)];
    case "extraUsage": {
      const extra = windows.find(w => /extra/i.test(w.label));
      return extra ? [clampPct(extra.remainingPct)] : [clampPct(windows[0].remainingPct)];
    }
    case "average": {
      const avg = windows.reduce((sum, w) => sum + w.remainingPct, 0) / windows.length;
      return [clampPct(avg)];
    }
    case "monthlyPlan": {
      const monthly = windows.find(w => /monthly|plan/i.test(w.label));
      return monthly ? [clampPct(monthly.remainingPct)] : [clampPct(windows[0].remainingPct)];
    }
    default:
      // Unknown preference: fallback to automatic
      const primaryWindows = s.windows.filter(w => w.label !== "Số dư" && !/bonus|balance/i.test(w.label));
      const candidates = primaryWindows.length > 0 ? primaryWindows : s.windows;
      if (candidates.length === 0) return [];
      // Copy array before sorting
      const sorted = [...candidates].sort((a, b) => {
        const aExhausted = a.remainingPct <= 0;
        const bExhausted = b.remainingPct <= 0;
        if (aExhausted !== bExhausted) return aExhausted ? -1 : 1;
        return (b.usedPct ?? 0) - (a.usedPct ?? 0);
      });
      return [clampPct(sorted[0].remainingPct)];
  }
}

/** Active = any window still consuming quota (remaining under 100 or used over 0).
 * Mirrors macOS `MenuBarIconRenderer.isActiveMenuBarFrame`. */
function isActiveTrayProvider(s: ProviderStatus): boolean {
  return s.windows.some((w) => w.remainingPct < 100 || (w.usedPct ?? 0) > 0);
}

function loadTrayLogo(id: string): Promise<HTMLImageElement | null> {
  const url = logoUrl(id);
  if (!url) return Promise.resolve(null);
  return new Promise((resolve) => {
    const img = new Image();
    img.decoding = "async";
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = url;
  });
}

/** Bounding box of non-transparent pixels, or null when fully transparent.
 * Used to strip the transparent margin brand SVGs ship with. */
function opaqueBounds(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
): { x: number; y: number; w: number; h: number } | null {
  const { data } = ctx.getImageData(0, 0, w, h);
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (data[(y * w + x) * 4 + 3] === 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return null;
  return { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 };
}

/**
 * Paint `91%` then the provider logo into one PNG — macOS parity, one line.
 *
 * macOS sets the percent as the status button's `title` and the logo as its
 * `image` (imageRight), so AppKit lays out 12pt text beside an 18pt logo in a
 * 24pt-tall slot. GNOME has no equivalent: its StatusNotifier label paints at
 * full system type size, so the percent has to live inside the icon bitmap.
 *
 * The catch is that the panel fits that bitmap into a ~22px **square** slot,
 * scaling by whichever side is larger. Every wasted pixel of width therefore
 * shrinks the glyphs: at 94x64 the panel scaled by 0.23 and rendered the
 * percent near 8px. Keeping the canvas tight to the content (~1.4 aspect,
 * matching macOS's text+logo proportions) lifts that to ~0.5.
 */
async function renderPercentProviderIcon(
  providerId: string,
  percentText: string,
): Promise<number[] | null> {
  // Size tag busts cache when we retune metrics.
  const cacheKey = `v16|${providerId}|${percentText}`;
  const cached = trayIconCache.get(cacheKey);
  if (cached) return cached;

  // macOS proportions inside a 32pt-tall box. The panel scales this bitmap to
  // the panel height and keeps its aspect, so the on-screen glyph size follows
  // `fontPx / height` — width is free, but an oversized font reads as shouting
  // next to GNOME's own indicators.
  // The panel scales this bitmap to the panel height and keeps its aspect, so
  // on-screen size follows `ink height / canvas height` — NOT the nominal font
  // size. Growing the logo to "fill" the box therefore just makes the logo
  // huge next to unchanged digits; keep both proportional to each other.
  const height = 32;
  // Trimming the logo's transparent margin (below) also shrank the canvas, and
  // because the panel scales by height a narrower bitmap reads smaller overall
  // — so the glyphs need to grow back to land at the size they did before.
  const fontPx = 16;
  const iconPx = 22;
  const gap = 3;
  const dpr = Math.min(3, Math.max(2, Math.round(window.devicePixelRatio || 2)));
  // Bold, and Ubuntu/DejaVu ahead of `system-ui`: the panel downscales this
  // bitmap, and `system-ui` has no real bold cut in WebKitGTK, so a heavier
  // weight silently synthesised back to regular and lost strokes on the way.
  const font = `700 ${fontPx}px Ubuntu, "DejaVu Sans", "Noto Sans", system-ui, sans-serif`;

  const measure = document.createElement("canvas").getContext("2d");
  if (!measure) return null;
  measure.font = font;
  // `width` is the advance, which bold faces overhang; use the painted extent
  // so the logo cannot land on the tail of the "%" glyph.
  const m = measure.measureText(percentText);
  const textW = Math.ceil(Math.max(m.width, m.actualBoundingBoxRight ?? m.width)) + 1;

  const width = textW + gap + iconPx;
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(width * dpr);
  canvas.height = Math.ceil(height * dpr);
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, width, height);

  ctx.font = font;
  ctx.fillStyle = "#ffffff";
  ctx.textBaseline = "middle";
  ctx.textAlign = "left";
  // Optical center: alphabetic middle sits slightly high on sans faces.
  ctx.fillText(percentText, 0, height / 2 + 0.75);

  const logo = await loadTrayLogo(providerId);
  let drawnW = 0;
  if (logo) {
    // Offscreen: draw logo then white-tint alpha (macOS menu-bar logo tint).
    const off = document.createElement("canvas");
    off.width = Math.ceil(iconPx * dpr);
    off.height = Math.ceil(iconPx * dpr);
    const octx = off.getContext("2d");
    if (octx) {
      octx.imageSmoothingEnabled = true;
      octx.imageSmoothingQuality = "high";
      octx.drawImage(logo, 0, 0, off.width, off.height);
      octx.globalCompositeOperation = "source-in";
      octx.fillStyle = "#ffffff";
      octx.fillRect(0, 0, off.width, off.height);
      // Brand SVGs carry their own transparent margin, which showed up as dead
      // space between the digits and the panel edge. Measure the painted box
      // and blit only that, so the mark sits flush in the tray slot.
      const ink = opaqueBounds(octx, off.width, off.height);
      if (ink) {
        const scale = iconPx / Math.max(ink.w, ink.h);
        drawnW = ink.w * scale / dpr;
        ctx.drawImage(
          off,
          ink.x, ink.y, ink.w, ink.h,
          textW + gap, (height - (ink.h * scale) / dpr) / 2,
          drawnW, (ink.h * scale) / dpr,
        );
      } else {
        drawnW = iconPx;
        ctx.drawImage(off, textW + gap, (height - iconPx) / 2, iconPx, iconPx);
      }
    }
  }

  // Trim the reserved-but-unused tail (the logo usually paints narrower than
  // `iconPx` once its own margin is gone) so the tray slot has no dead space.
  const usedW = Math.ceil(textW + gap + (drawnW || iconPx));
  let out: HTMLCanvasElement = canvas;
  if (usedW < width) {
    const tight = document.createElement("canvas");
    tight.width = Math.ceil(usedW * dpr);
    tight.height = canvas.height;
    tight.getContext("2d")?.drawImage(canvas, 0, 0);
    out = tight;
  }

  const blob = await new Promise<Blob | null>((resolve) =>
    out.toBlob((b) => resolve(b), "image/png"));
  if (!blob) return null;
  const buf = new Uint8Array(await blob.arrayBuffer());
  const bytes = Array.from(buf);
  trayIconCache.set(cacheKey, bytes);
  // Bound cache growth when percents churn.
  if (trayIconCache.size > 64) {
    const first = trayIconCache.keys().next().value;
    if (first !== undefined) trayIconCache.delete(first);
  }
  return bytes;
}

/**
 * Tray frames: active first, then A→Z by displayName
 * (macOS `MenuBarIconRenderer.providerFrames` parity).
 *
 * Reads `menuBarMetric` from ProviderStatus if present, otherwise
 * falls back to settings lookup. Uses pure `resolveTrayMetric` resolver.
 */
async function buildTrayFrames(statuses: ProviderStatus[], hidden: Set<string>): Promise<Omit<TrayFrame, "iconPng">[]> {
  if (!isShowTrayPercentEnabled()) return [];

  // Try to read metric from ProviderStatus first (if wired from Rust)
  // Fall back to settings lookup only if needed
  const settings = await invoke<Settings>("get_settings").catch(() => null);
  const metricById = new Map<string, string | null>();
  if (settings) {
    for (const p of settings.providers) {
      metricById.set(p.id, p.menuBarMetric ?? null);
    }
  }

  return statuses
    .filter((s) => !hidden.has(s.id) && !s.error && s.windows.length > 0
      && (s.id !== "antigravity" || resolveTrayMetric(s, metricById.get(s.id)).length > 0))
    .map((s) => {
      const metric = metricById.get(s.id) ?? null;
      const percents = resolveTrayMetric(s, metric);
      const pctText = percents.length > 0
        ? percents.map((p) => `${clampPct(p)}%`).join("  ")
        : (lowestWindow(s) ? `${clampPct(lowestWindow(s)!.remainingPct)}%` : "");
      // `.filter` above guarantees s.windows.length > 0, so lowestWindow
      // always returns non-null here.
      const lowest = lowestWindow(s)!;
      return {
        providerId: s.id,
        percentText: pctText || trayPercentText(s),
        tooltipPart: `${s.displayName} ${clampPct(lowest.remainingPct)}%`,
        active: isActiveTrayProvider(s),
        sortName: s.displayName,
      };
    })
    .sort((a, b) => {
      if (a.active !== b.active) return a.active ? -1 : 1;
      return a.sortName.localeCompare(b.sortName, undefined, { sensitivity: "base" });
    })
    .map(({ providerId, percentText, tooltipPart }) => ({
      providerId,
      percentText,
      tooltipPart,
    }));
}

function applyTrayFrame() {
  const tooltip = trayFrames.length
    ? trayFrames.map((f) => f.tooltipPart).join(" · ")
    : "BirdNion";
  if (!trayFrames.length) {
    // Bird / logo-only frame — restore default app icon, clear title.
    void invoke("set_tray_status", {
      tooltip,
      title: null,
      iconPng: null,
    }).catch(() => {});
    return;
  }
  const frame = trayFrames[trayFrameIndex % trayFrames.length]!;
  // Never put the percent in StatusNotifier `title`: GNOME paints that label
  // at full panel type size (the oversized "59%" next to the bird). Percent
  // lives only inside the composite PNG; if paint failed, bird-only + tooltip.
  void invoke("set_tray_status", {
    tooltip,
    title: null,
    iconPng: frame.iconPng,
  }).catch(() => {});
}

function startTrayRotation() {
  if (trayRotationTimer != null) return;
  trayRotationTimer = setInterval(() => {
    if (trayFrames.length <= 1) return;
    trayFrameIndex = (trayFrameIndex + 1) % trayFrames.length;
    applyTrayFrame();
  }, TRAY_FRAME_MS);
}

function stopTrayRotation() {
  if (trayRotationTimer != null) {
    clearInterval(trayRotationTimer);
    trayRotationTimer = null;
  }
}

/** Mirror the macOS menu-bar percent readout: rotating `%` + provider logo.
 * Providers with `showInTray === false` are skipped (`MenuBarVisibility`).
 * When Display → show-% is off, restore the default logo only. */
async function updateTrayTooltip(statuses: ProviderStatus[], hidden: Set<string>) {
  const built = await buildTrayFrames(statuses, hidden);
  const withIcons: TrayFrame[] = await Promise.all(
    built.map(async (f) => ({
      ...f,
      iconPng: await renderPercentProviderIcon(f.providerId, f.percentText),
    })),
  );
  trayFrames = withIcons;
  if (trayFrameIndex >= trayFrames.length) trayFrameIndex = 0;
  applyTrayFrame();
  if (trayFrames.length > 1) startTrayRotation();
  else stopTrayRotation();
}

/** Data Confidence Pass: keep the previous `serviceStatus`/`serviceStatusLevel`
 * for one provider id when its quota update just succeeded but the side
 * status-page probe came back empty this cycle — a transient probe miss
 * shouldn't blank a value the UI already had. Any incoming non-nil value
 * always wins outright, and an errored update is left completely untouched
 * (unchanged from prior behavior; the error banner still shows as-is). */
function withLastGoodServiceStatus(cached: ProviderStatus | undefined, fresh: ProviderStatus): ProviderStatus {
  if (fresh.error) return fresh;
  if (fresh.serviceStatus != null || fresh.serviceStatusLevel != null) return fresh;
  if (!cached || (cached.serviceStatus == null && cached.serviceStatusLevel == null)) return fresh;
  return { ...fresh, serviceStatus: cached.serviceStatus, serviceStatusLevel: cached.serviceStatusLevel };
}

/** Mirrors macOS `ProviderStatus.isRenderableSnapshot` — a prior status with
 * meaningful content worth preserving across a transient refresh error. */
function isRenderableSnapshot(status: ProviderStatus): boolean {
  if (status.error) return false;
  return (
    status.windows.length > 0 ||
    status.creditsRemaining != null ||
    status.creditsUnlimited === true ||
    status.planType != null ||
    status.planName != null ||
    status.accountLabel != null ||
    status.version != null ||
    status.serviceStatus != null ||
    status.signedInEmail != null ||
    status.sourceLabel != null
  );
}

/** Per-provider stale-data warning (see `StaleQuotaWarning` in
 * `provider-tab.ts`), populated only while a *transient* refresh error is
 * being suppressed behind a preserved last-good snapshot. Deliberately kept
 * OUT of `ProviderStatus`: nothing on Linux persists `state.statuses` across
 * a relaunch either, so this map always starts empty on a fresh launch. */
const staleWarnings = new Map<string, StaleQuotaWarning>();

function staleWarningFor(id: string): StaleQuotaWarning | undefined {
  return staleWarnings.get(id);
}

/** Last-good policy (macOS `QuotaService` parity): keep showing the cached
 * status instead of collapsing to an error-only card when the fresh error is
 * *transient* (network/timeout, rate-limit, genuine 5xx — see the shared
 * Rust classifier `is_transient_provider_error`) AND the cache still holds a
 * renderable snapshot. Any other error (credential, cookie, schema, unknown)
 * always replaces with the fresh error status — those numbers can no longer
 * be trusted. A successful fresh status is untouched here beyond the
 * existing service-status gap-fill. Fresh success or a non-transient error
 * both clear any previously recorded `staleWarnings` entry for this id. */
async function withLastGood(cached: ProviderStatus | undefined, fresh: ProviderStatus): Promise<ProviderStatus> {
  if (!fresh.error) {
    staleWarnings.delete(fresh.id);
    return withLastGoodServiceStatus(cached, fresh);
  }
  if (!cached || !isRenderableSnapshot(cached)) {
    staleWarnings.delete(fresh.id);
    return fresh;
  }
  const transient = await invoke<boolean>("is_transient_provider_error", { raw: fresh.error }).catch(() => false);
  if (!transient) {
    staleWarnings.delete(fresh.id);
    return fresh;
  }
  const kind = (await invoke<string | null>("classify_provider_error", { raw: fresh.error }).catch(() => null)) ?? "unknown";
  staleWarnings.set(fresh.id, { kind, lastGoodUpdated: cached.lastUpdated });
  return cached;
}

/** Merge freshly fetched statuses over the cached ones by id, preserving the
 * **cached order** (which is settings.providers order via seed/rebuild).
 * New ids not yet in cache are appended. */
async function mergeStatuses(cached: ProviderStatus[], fresh: ProviderStatus[]): Promise<ProviderStatus[]> {
  const byId = new Map(cached.map((s) => [s.id, s]));
  for (const s of fresh) byId.set(s.id, await withLastGood(byId.get(s.id), s));
  const order = [...cached.map((s) => s.id)];
  for (const s of fresh) if (!order.includes(s.id)) order.push(s.id);
  return order.map((id) => byId.get(id)!).filter(Boolean);
}

async function fetchTrayHidden(): Promise<Set<string>> {
  const settings = await invoke<Settings>("get_settings").catch(() => null);
  if (!settings) return new Set();
  return new Set(settings.providers.filter((p) => p.showInTray === false).map((p) => p.id));
}

/** Placeholder statuses for every enabled provider — the macOS
 * `displayStatuses` seed: tabs and skeleton cards paint immediately, each
 * card fills in as its own fetch lands. Existing statuses are kept as-is
 * (stale-data-first) so a refresh never flashes back to skeletons.
 *
 * **Order always follows `settings.providers` enabled order** so the tab
 * strip matches Settings → Nhà cung cấp active list. */
function seedPlaceholderStatuses(settings: Settings | null) {
  if (!settings) return;
  const existing = new Map(state.statuses.map((s) => [s.id, s]));
  state.statuses = settings.providers
    .filter((p) => p.enabled === true)
    .map((p) => existing.get(p.id) ?? {
      id: p.id,
      displayName: p.displayName?.trim() || NAME_BY_ID.get(p.id) || p.id,
      windows: [],
      lastUpdated: 0,
      pending: true,
    });
}

/**
 * Rebuild tab strip order from disk after Settings reorder / enable toggle
 * (macOS `rebuildProviders` on `.birdnionProvidersChanged`). Keeps cached
 * quota data for providers that stay enabled.
 */
async function rebuildProviderOrderFromSettings() {
  if (isSettingsWindow()) return;
  const settings = await invoke<Settings>("get_settings").catch(() => null);
  if (!settings) {
    await rebuildActionCenterInputs(null);
    return;
  }
  seedPlaceholderStatuses(settings);
  await rebuildActionCenterInputs(settings);
  // Drop lastFetched for providers no longer enabled so a re-enable refetches.
  const keep = new Set(state.statuses.map((s) => s.id));
  for (const id of [...lastFetched.keys()]) {
    if (!keep.has(id)) {
      lastFetched.delete(id);
      adaptiveFailureStreaks.delete(id);
    }
  }
  for (const id of [...staleWarnings.keys()]) {
    if (!keep.has(id)) staleWarnings.delete(id);
  }
  if (state.tab !== "all" && !keep.has(state.tab)) {
    state.tab = state.statuses[0]?.id ?? "all";
    localStorage.setItem(TAB_KEY, state.tab);
  }
  await refreshActionCenterIssues();
  render();
  void updateTrayTooltip(state.statuses, await fetchTrayHidden()).catch(() => {});
}

/** Initial full load (all enabled providers) plus the local usage reports.
 * macOS QuotaService parity: every fetch publishes into state and re-renders
 * as soon as IT finishes — the UI never waits for the slowest source. */
async function load(manual = false) {
  if (isSettingsWindow()) return;
  if (loadInFlight) return;
  loadInFlight = true;
  state.refreshing = true;
  // Marked up-front (not per-invoke) so the very first paint below already
  // shows the All-tab skeleton/scanning hint instead of "no logs found".
  state.scanning = new Set(SCAN_SOURCES);

  // Publish one source's result and repaint. Chrome-only repaint while a
  // provider tab shows fresh-enough data would be nice, but a full render()
  // per arrival is cheap (~ms) and keeps this simple; render() is idempotent.
  const publish = (apply: () => void) => {
    apply();
    render();
  };

  const scanReport = (source: ScanSource) =>
    invoke<UsageReport | null>(`${source}_usage_report`)
      .catch(() => null)
      .then((report) => publish(() => {
        state.scanning.delete(source);
        // Keep the previous report when a rescan fails/returns empty.
        if (report) state[source] = report;
      }));

  // First launch: replace the static index.html loading div with the app
  // frame (header + tab strip) before ANY await — the macOS popover always
  // has its chrome on screen. Re-loads keep the soft chrome-only update —
  // a full render() here wiped charts and re-spun the ↻ icon on every
  // concurrent call (focus/open-settings races).
  if (state.loadedOnce) paintRefreshChrome();
  else render();

  try {
    // Placeholder tabs/skeleton cards for every enabled provider, so each
    // card fills in as its own fetch lands (macOS displayStatuses seed).
    const settings = await invoke<Settings>("get_settings").catch(() => null);
    seedPlaceholderStatuses(settings);
    if (!state.loadedOnce) render();

    // Per-provider streaming (macOS QuotaService TaskGroup): each provider's
    // card fills in the moment ITS fetch lands — a 15s-timeout provider never
    // holds up the others. Falls back to one batch call when settings are
    // unreadable (no id list to fan out over).
    const publishStatuses = async (requestedIds: string[], fresh: ProviderStatus[]) => {
      const prevIds = state.statuses.map((s) => s.id).join(",");
      recordFetchOutcomes(requestedIds, fresh, manual);
      state.statuses = state.statuses.length > 0 ? await mergeStatuses(state.statuses, fresh) : fresh;
      await refreshActionCenterIssues();
      checkQuotaWarnings(fresh);
      evaluateFailureEpisodes(fresh);
      // Same gating as tick(): statuses don't feed the All-tab charts, so
      // only repaint there when the tab strip set itself changed.
      const nextIds = state.statuses.map((s) => s.id).join(",");
      if (state.tab !== "all" || prevIds !== nextIds) render();
    };
    const enabledIds = settings?.providers.filter((p) => p.enabled === true).map((p) => p.id) ?? [];
    const detectionDone = rebuildActionCenterInputs(settings);
    const statusesDone = (enabledIds.length > 0
      // Per-id guard: skips a provider `refetchProvider()` or `tick()` is
      // already fetching instead of firing a duplicate request for it.
      ? Promise.all(enabledIds.map((id) =>
          withProviderInFlightGuard(id, () =>
            invoke<ProviderStatus[]>("provider_statuses", { ids: [id] })
              .catch(() => [] as ProviderStatus[])
              .then((fresh) => publishStatuses([id], fresh)))))
      // Settings were unreadable, so the enabled-id list itself is unknown
      // up front — this batch fetch can't be claimed per-id before firing.
      // Rare/degraded path (`get_settings` itself failed); accepted gap.
      : invoke<ProviderStatus[]>("provider_statuses", { ids: null })
          .catch(() => [] as ProviderStatus[])
          .then((fresh) => publishStatuses(fresh.map((status) => status.id), fresh))
    ).then(async () => updateTrayTooltip(state.statuses, await fetchTrayHidden()));

    // Cả 6 nguồn chi phí đều được quét, kể cả agent không có provider (omp,
    // pi, kiro): backend tự quyết định qua `enabled_usage_sources()` — bật
    // provider HOẶC phát hiện agent trên máy — nên tắt provider không còn làm
    // mất chi phí của CLI đó (macOS parity 2026-08-24).
    // Catalog agent: nguồn cho hàng "đã cấu hình" ở tab All. Lỗi dò không
    // được làm hỏng lần load — hàng đó chỉ đơn giản không hiện.
    void invoke<InstalledAgent[]>("list_installed_agents")
      .catch(() => [] as InstalledAgent[])
      .then((agents) => publish(() => { state.agents = agents; }));

    const usageDone = Promise.all(SCAN_SOURCES.map((id) => scanReport(id))).then(async () => {
      const insights = await fetchProjectInsightsReport(7);
      publish(() => { state.insights = insights; });
    });

    await Promise.all([
      usageDone,
      statusesDone,
      detectionDone,
      invoke<ClaudeAdminSnapshot | null>("claude_admin_usage")
        .catch(() => null)
        .then((snap) => publish(() => { state.claudeAdmin = snap; })),
    ]);
    state.loadedOnce = true;
  } finally {
    loadInFlight = false;
    state.refreshing = false;
    state.scanning.clear();
    // Any placeholder whose fetch never returned (IPC failure) must not
    // spin forever — degrade to the regular "no quota data" card.
    for (const s of state.statuses) delete s.pending;
    await refreshActionCenterIssues();
    render();
  }
}

/** Re-fetches ONE provider immediately (e.g. after an account switch or the
 * user clicking Retry) and merges the fresh status over the cached state.
 * Guarded by `inFlightProviderIds`: a no-op when `load()` or `tick()` is
 * already fetching this same provider — "don't create a duplicate request"
 * — the in-flight caller's own completion still applies the result. */
async function refetchProvider(id: string) {
  if (isSettingsWindow()) return;
  await withProviderInFlightGuard(id, async () => {
    const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids: [id] }).catch(() => []);
    recordFetchOutcomes([id], fresh, true);
    if (fresh.length === 0) return;
    state.statuses = await mergeStatuses(state.statuses, fresh);
    await refreshActionCenterIssues();
    checkQuotaWarnings(fresh);
    await updateTrayTooltip(state.statuses, await fetchTrayHidden());
    render();
  });
}

/** Tick: only re-fetch providers whose own effective interval elapsed,
 * merging fresh results over the cached state so unaffected tabs don't
 * flicker back to "loading". */
async function tick() {
  if (isSettingsWindow() || loadInFlight) return;
  // Weekly Digest rides this existing cadence — evaluated even when no
  // provider quota is due this cycle (its own 7-day/in-flight gates decide).
  void checkWeeklyDigest().catch(() => {});
  const due = await dueProviderIds();
  if (!due || due.length === 0) return;
  // Exclude ids an earlier, still-unresolved tick already requested — see
  // `inFlightProviderIds`.
  const ids = eligibleForFetch(due, inFlightProviderIds);
  if (ids.length === 0) return;
  const prevIds = state.statuses.map((s) => s.id).join(",");
  for (const id of ids) inFlightProviderIds.add(id);
  try {
    const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
    recordFetchOutcomes(ids, fresh, false);
    state.statuses = await mergeStatuses(state.statuses, fresh);
    await refreshActionCenterIssues();
    checkQuotaWarnings(state.statuses);
    evaluateFailureEpisodes(fresh);
    await updateTrayTooltip(state.statuses, await fetchTrayHidden());
    // Avoid rebuilding the All-tab charts every 10s (felt like constant spin/flicker).
    // Re-render only when the tab strip set changed, or user is on a provider tab.
    const nextIds = state.statuses.map((s) => s.id).join(",");
    const onProviderTab = state.tab !== "all";
    if (onProviderTab || prevIds !== nextIds) {
      render();
    }
  } finally {
    for (const id of ids) inFlightProviderIds.delete(id);
  }
}

/** Explicit "Refresh now" action (settings button / manual mode's only
 * fetch path): re-runs the same full fetch as the initial `load()`, so it
 * works regardless of the current global-interval mode. */
async function refreshNow() {
  if (isSettingsWindow()) return;
  await load(true);
}

/** Ctrl/Cmd+, → Settings window; Ctrl/Cmd+Q → Quit (macOS popover shortcuts). */
window.addEventListener("keydown", (ev) => {
  if (isSettingsWindow()) return;
  const mod = ev.metaKey || ev.ctrlKey;
  if (mod && ev.key === ",") {
    ev.preventDefault();
    openSettings("general");
  }
  if (mod && (ev.key === "q" || ev.key === "Q")) {
    ev.preventDefault();
    void invoke("quit_app").catch(() => { window.close(); });
  }
});

/** Refresh-on-open: re-fetch all providers whenever the window regains focus
 * (mirrors macOS `refreshOnMenuOpen`), gated by the settings toggle.
 * Debounced + suppressed right after opening Settings (focus thrash). */
let focusRefreshTimer: ReturnType<typeof setTimeout> | null = null;
void getCurrentWindow().onFocusChanged(({ payload: focused }) => {
  if (isSettingsWindow()) return;
  if (!focused || !isRefreshOnOpenEnabled()) return;
  if (Date.now() < suppressFocusRefreshUntil) return;
  if (focusRefreshTimer) clearTimeout(focusRefreshTimer);
  focusRefreshTimer = setTimeout(() => {
    focusRefreshTimer = null;
    if (Date.now() < suppressFocusRefreshUntil) return;
    void refreshNow().catch(() => {});
  }, 400);
});

/** Rebuild tray title when Display → show-% toggles (Settings is another
 * webview — `storage` for cross-window, custom event for same-window). */
function onTrayDisplayPrefChanged() {
  if (isSettingsWindow()) return;
  void fetchTrayHidden()
    .then((hidden) => updateTrayTooltip(state.statuses, hidden))
    .catch(() => {});
}
window.addEventListener("storage", (e) => {
  if (e.key === "birdnion.showPercentInTray") onTrayDisplayPrefChanged();
});
window.addEventListener("birdnion-tray-display-changed", onTrayDisplayPrefChanged);

/** Repaint the All-tab budget card when the monthly budget changes —
 * Settings is another webview (`storage` for cross-window, custom event for
 * same-window; mirrors `onTrayDisplayPrefChanged`). */
function onMonthlyBudgetChanged() {
  if (isSettingsWindow()) return;
  if (state.tab === "all") render();
}
window.addEventListener("storage", (e) => {
  if (e.key === MONTHLY_BUDGET_STORAGE_KEY) onMonthlyBudgetChanged();
});
window.addEventListener(MONTHLY_BUDGET_CHANGED_EVENT, onMonthlyBudgetChanged);

/** Repaint the current provider tab's budget card when its own Claude/Codex/
 * Grok budget changes — same webview-relay pattern as `onMonthlyBudgetChanged`. */
function onProviderBudgetChanged() {
  if (isSettingsWindow()) return;
  if (state.tab === "claude" || state.tab === "codex" || state.tab === "grok") render();
}
const providerBudgetKeys = new Set(Object.values(PROVIDER_BUDGET_STORAGE_KEYS));
window.addEventListener("storage", (e) => {
  if (e.key && providerBudgetKeys.has(e.key)) onProviderBudgetChanged();
});
window.addEventListener(PROVIDER_BUDGET_CHANGED_EVENT, onProviderBudgetChanged);

window.addEventListener("DOMContentLoaded", () => {
  initTheme();
  if (isSettingsWindow()) {
    document.title = "BirdNion Settings";
    window.__BIRDNION_MODE__ = "settings";
    void mountSettingsWindow(() => {
      // Order already emitted via PROVIDERS_CHANGED_EVENT on save/reorder.
    }).catch((err) => {
      document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
    });
    return;
  }
  // Settings webview → main: rebuild tab order (macOS providersDidChange).
  void listen(PROVIDERS_CHANGED_EVENT, () => {
    void rebuildProviderOrderFromSettings().catch(() => {});
  });
  // Settings webview → main: tray-percent toggled. Must be a Tauri event —
  // Settings is a separate webview, so its `storage`/DOM events never arrive
  // here, and the rotation timer would keep repainting the percent frame.
  void listen(TRAY_DISPLAY_CHANGED_EVENT, () => {
    onTrayDisplayPrefChanged();
  });
  void listen(ACTION_CENTER_SNAPSHOT_REQUEST_EVENT, () => {
    if (actionCenterSnapshotError) {
      void rebuildProviderOrderFromSettings().catch(() => {});
      return;
    }
    const snapshot: ActionCenterSnapshot = {
      issues: currentActionCenterIssues,
      ready: actionCenterSnapshotReady,
      error: actionCenterSnapshotError,
    };
    void emit(ACTION_CENTER_UPDATED_EVENT, snapshot).catch(() => {});
  });
  void listen<{ providerId?: string }>(ACTION_CENTER_RETRY_EVENT, (event) => {
    const providerId = event.payload?.providerId;
    if (!providerId || !currentActionCenterIssues.some((issue) => issue.providerId === providerId)) return;
    void refetchProvider(providerId)
      .finally(() => emit(ACTION_CENTER_UPDATED_EVENT, {
        issues: currentActionCenterIssues,
        ready: actionCenterSnapshotReady,
        error: actionCenterSnapshotError,
      } satisfies ActionCenterSnapshot).catch(() => {}));
  });
  void listen<ProviderStatus>(GUIDED_SETUP_STATUS_EVENT, (event) => {
    const status = event.payload;
    if (!["claude", "codex", "grok"].includes(status.id)) return;
    void (async () => {
      state.statuses = await mergeStatuses(state.statuses, [status]);
      await refreshActionCenterIssues();
      render();
    })();
  });
  load().catch((err) => {
    document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
  });
  setInterval(() => void tick().catch(() => {}), TICK_MS);
});
