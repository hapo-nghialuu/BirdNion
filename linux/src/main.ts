import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-sans/700.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "@fontsource/ibm-plex-mono/600.css";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard, confidenceRow, budgetForecastCard } from "./all-tab";
import { providerCard, claudeCodeQuickApplyCard, loadingSkeleton, lowestWindow, ProviderStatus } from "./provider-tab";
import { freemodelAccountsPopoverCard } from "./freemodel-accounts-popover";
import { elevenlabsKeysPopoverCard } from "./elevenlabs-keys-popover";
import { codexAccountsPopoverCard } from "./codex-accounts-popover";
import { NAME_BY_ID, PROVIDERS_CHANGED_EVENT } from "./settings-tab";
import { sourceChartCard } from "./source-chart";
import { adminChartCard, ClaudeAdminSnapshot } from "./admin-chart";
import { t } from "./i18n";
import {
  getPollSeconds, isManualRefresh, isRefreshOnOpenEnabled, effectiveQuotaWarn,
  isShowTrayPercentEnabled, getMonthlyBudgetUsd, MONTHLY_BUDGET_STORAGE_KEY,
  MONTHLY_BUDGET_CHANGED_EVENT,
} from "./settings-about";
import { currentMonitor, getCurrentWindow } from "@tauri-apps/api/window";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { logoMark, logoUrl, providerTintCss } from "./logos";
import { mountSettingsWindow } from "./settings-window";
import { settingsIcon } from "./settings-icons";
import { initTheme, getAppearance, setAppearance, type Appearance } from "./theme";
import { checkWeeklyDigest } from "./weekly-digest";

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

/** Local usage-report sources scanned from disk (Claude → Codex → Grok). */
const SCAN_SOURCES = ["claude", "codex", "grok"] as const;
type ScanSource = (typeof SCAN_SOURCES)[number];

type State = {
  claude: UsageReport | null;
  codex: UsageReport | null;
  grok: UsageReport | null;
  statuses: ProviderStatus[];
  claudeAdmin: ClaudeAdminSnapshot | null;
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
  statuses: [],
  claudeAdmin: null,
  tab: (() => {
    const t0 = localStorage.getItem(TAB_KEY) || "all";
    return t0 === "settings" ? "all" : t0;
  })(),
  refreshing: false,
  loadedOnce: false,
  scanning: new Set<ScanSource>(),
};

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

function openSettings(section?: string) {
  if (section) localStorage.setItem("birdnion.settingsSection", section);
  // Opening Settings steals focus from main — don't immediately re-load main.
  suppressFocusRefreshUntil = Date.now() + 1500;
  void invoke("open_settings_window").catch((err) => {
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
  state.tab = id;
  localStorage.setItem(TAB_KEY, id);
  render();
}

/** macOS BirdNionHeader remake: logo + title + status + refresh + appearance. */
function appHeader(): HTMLElement {
  const head = el("header", "app-header");
  const brand = el("div", "app-brand");
  const icon = document.createElement("img");
  icon.className = "app-logo";
  icon.src = "/logos/app.png";
  icon.alt = "BirdNion";
  icon.draggable = false;
  const titles = el("div", "app-titles");
  titles.append(el("div", "app-title", "BirdNion"));
  brand.append(icon, titles);

  // Status pill (ready / updating)
  const refreshing = state.refreshing;
  const pill = el("div", `status-pill${refreshing ? " updating" : " ready"}`);
  pill.append(el("span", "status-pill-dot"));
  pill.append(el("span", "status-pill-text",
    refreshing ? t("popoverUpdating")
      : state.loadedOnce ? t("popoverReady") : "…"));
  brand.append(pill);

  const actions = el("div", "header-actions");
  const refresh = document.createElement("button");
  refresh.type = "button";
  refresh.className = `header-refresh${refreshing ? " spinning" : ""}`;
  refresh.title = t("popoverRefresh");
  refresh.setAttribute("aria-label", t("popoverRefresh"));
  refresh.disabled = refreshing;
  refresh.append(settingsIcon("arrow.clockwise", "header-refresh-icon"));
  refresh.addEventListener("click", () => { void refreshNow(); });

  // Design: sun/moon cycles appearance; Settings is a footer text link.
  const appearance = getAppearance();
  const appearanceIcon =
    appearance === "light" ? "sun.max" : appearance === "dark" ? "moon" : "circle.lefthalf.filled";
  const themeBtn = document.createElement("button");
  themeBtn.type = "button";
  themeBtn.className = "header-refresh header-appearance";
  themeBtn.title = t("appearanceTitle");
  themeBtn.setAttribute("aria-label", t("appearanceTitle"));
  themeBtn.append(settingsIcon(appearanceIcon, "header-refresh-icon"));
  themeBtn.addEventListener("click", () => {
    const cur = getAppearance();
    const next: Appearance = cur === "light" ? "dark" : cur === "dark" ? "auto" : "light";
    setAppearance(next);
    render();
  });

  actions.append(refresh, themeBtn);
  head.append(brand, actions);
  return head;
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

/** Footer: "CẬP NHẬT …" left + icon buttons Settings / About / Quit (macOS parity). */
function popoverFooter(): HTMLElement {
  const foot = el("footer", "popover-footer footer-compact");

  let latest = 0;
  for (const s of state.statuses) {
    if (s.lastUpdated && s.lastUpdated > latest) latest = s.lastUpdated;
  }
  if (latest > 0) {
    const rel = relativeTime(latest);
    if (rel) foot.append(el("span", "footer-updated", t("lastUpdated", { time: rel })));
  } else {
    foot.append(el("span", "footer-updated", ""));
  }

  const actions = el("div", "footer-actions");
  const mkIcon = (sf: string, label: string, extraClass: string, onClick: () => void) => {
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

  if (state.tab === "all") {
    const pending = pendingScanSources();
    if (!state.claude && !state.codex && !state.grok) {
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
      const combined = combine(state.claude, state.codex, state.grok);
      // Design order: chart/share → confidence → budget → heatmap → models.
      body.append(chartCard(combined, state.claude?.hourly ?? []));
      body.append(confidenceRow(state.claude, state.codex, state.grok, pending));
      const budget = budgetForecastCard(combined, getMonthlyBudgetUsd());
      if (budget) body.append(budget);
      body.append(heatmapCard(combined));
      // Top models follow chart period chips (may hide itself if empty window).
      body.append(topModelsCard(combined));
    }
  } else {
    const status = state.statuses.find((s) => s.id === state.tab);
    if (status) {
      body.append(providerCard(status));
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
    // Codex: account switcher BELOW the cost chart (macOS CodexAccountsPopoverSection).
    if (state.tab === "codex") {
      body.append(codexAccountsPopoverCard(
        () => scheduleFitWindow(),
        () => { void refetchProvider("codex"); },
      ));
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

/**
 * Paint `91%` + provider logo into one PNG (percent left, logo right).
 *
 * Linux GNOME AppIndicator / StatusNotifier scales the tray image to the
 * **full panel height** (no fixed 18pt slot like macOS). Glyph size is
 * therefore a ratio of canvas height, not absolute px:
 *
 *   - GNOME top-bar text ≈ 36–42% of panel height (clock / locale chip).
 *   - v2 used 14/18 (78%) → huge. v3 used 12/22 (55%) → still oversized
 *     next to "vi" / network. v4 targets ≈ 38% with lighter weight.
 *
 * Never fall back to StatusNotifier `title` for the percent — the panel
 * paints that label at full system type size and it always looks too big.
 */
async function renderPercentProviderIcon(
  providerId: string,
  percentText: string,
): Promise<number[] | null> {
  // Size tag busts cache when we retune metrics.
  const cacheKey = `v4|${providerId}|${percentText}`;
  const cached = trayIconCache.get(cacheKey);
  if (cached) return cached;

  // Ratio template: text ~38% of canvas, logo ~46%, rest is breathing room
  // so the panel scale-up doesn't make glyphs fill the whole tray slot.
  const height = 32;
  const fontPx = 12; // 12/32 = 37.5% of canvas height
  const iconPx = 15; // 15/32 ≈ 47%
  const gap = 3;
  const padX = 2;
  const dpr = Math.min(3, Math.max(2, Math.round(window.devicePixelRatio || 2)));
  // Regular weight + UI sans (not mono 500): mono digits read heavier at the
  // same px size and looked "to" next to GNOME indicators.
  const font = `400 ${fontPx}px system-ui, "Segoe UI", Ubuntu, "Helvetica Neue", sans-serif`;

  const measure = document.createElement("canvas").getContext("2d");
  if (!measure) return null;
  measure.font = font;
  // ceil + 1px slack so anti-aliased edges aren't clipped after scale.
  const textW = Math.ceil(measure.measureText(percentText).width) + 1;

  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.ceil((padX + textW + gap + iconPx + padX) * dpr));
  canvas.height = Math.ceil(height * dpr);
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.font = font;
  ctx.fillStyle = "#ffffff";
  ctx.textBaseline = "middle";
  ctx.textAlign = "left";
  // Optical center: alphabetic middle sits slightly high on sans faces.
  ctx.fillText(percentText, padX, height / 2 + 0.75);

  const logo = await loadTrayLogo(providerId);
  if (logo) {
    const ix = padX + textW + gap;
    const iy = (height - iconPx) / 2;
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
      ctx.drawImage(off, ix, iy, iconPx, iconPx);
    }
  }

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob((b) => resolve(b), "image/png"));
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

/** Merge freshly fetched statuses over the cached ones by id, preserving the
 * **cached order** (which is settings.providers order via seed/rebuild).
 * New ids not yet in cache are appended. */
function mergeStatuses(cached: ProviderStatus[], fresh: ProviderStatus[]): ProviderStatus[] {
  const byId = new Map(cached.map((s) => [s.id, s]));
  for (const s of fresh) byId.set(s.id, withLastGoodServiceStatus(byId.get(s.id), s));
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
  if (!settings) return;
  seedPlaceholderStatuses(settings);
  // Drop lastFetched for providers no longer enabled so a re-enable refetches.
  const keep = new Set(state.statuses.map((s) => s.id));
  for (const id of [...lastFetched.keys()]) {
    if (!keep.has(id)) {
      lastFetched.delete(id);
      adaptiveFailureStreaks.delete(id);
    }
  }
  if (state.tab !== "all" && !keep.has(state.tab)) {
    state.tab = state.statuses[0]?.id ?? "all";
    localStorage.setItem(TAB_KEY, state.tab);
  }
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
    const publishStatuses = (requestedIds: string[], fresh: ProviderStatus[]) => {
      const prevIds = state.statuses.map((s) => s.id).join(",");
      recordFetchOutcomes(requestedIds, fresh, manual);
      state.statuses = state.statuses.length > 0 ? mergeStatuses(state.statuses, fresh) : fresh;
      checkQuotaWarnings(fresh);
      evaluateFailureEpisodes(fresh);
      // Same gating as tick(): statuses don't feed the All-tab charts, so
      // only repaint there when the tab strip set itself changed.
      const nextIds = state.statuses.map((s) => s.id).join(",");
      if (state.tab !== "all" || prevIds !== nextIds) render();
    };
    const enabledIds = settings?.providers.filter((p) => p.enabled === true).map((p) => p.id) ?? [];
    const statusesDone = (enabledIds.length > 0
      ? Promise.all(enabledIds.map((id) =>
          invoke<ProviderStatus[]>("provider_statuses", { ids: [id] })
            .catch(() => [] as ProviderStatus[])
            .then((fresh) => publishStatuses([id], fresh))))
      : invoke<ProviderStatus[]>("provider_statuses", { ids: null })
          .catch(() => [] as ProviderStatus[])
          .then((fresh) => publishStatuses(fresh.map((status) => status.id), fresh))
    ).then(async () => updateTrayTooltip(state.statuses, await fetchTrayHidden()));

    await Promise.all([
      scanReport("claude"),
      scanReport("codex"),
      scanReport("grok"),
      statusesDone,
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
    render();
  }
}

/** Re-fetches ONE provider immediately (e.g. after an account switch) and
 * merges the fresh status over the cached state. */
async function refetchProvider(id: string) {
  if (isSettingsWindow()) return;
  const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids: [id] }).catch(() => []);
  recordFetchOutcomes([id], fresh, true);
  if (fresh.length === 0) return;
  state.statuses = mergeStatuses(state.statuses, fresh);
  checkQuotaWarnings(fresh);
  await updateTrayTooltip(state.statuses, await fetchTrayHidden());
  render();
}

/** Tick: only re-fetch providers whose own effective interval elapsed,
 * merging fresh results over the cached state so unaffected tabs don't
 * flicker back to "loading". */
async function tick() {
  if (isSettingsWindow() || loadInFlight) return;
  // Weekly Digest rides this existing cadence — evaluated even when no
  // provider quota is due this cycle (its own 7-day/in-flight gates decide).
  void checkWeeklyDigest().catch(() => {});
  const ids = await dueProviderIds();
  if (!ids || ids.length === 0) return;
  const prevIds = state.statuses.map((s) => s.id).join(",");
  const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
  recordFetchOutcomes(ids, fresh, false);
  state.statuses = mergeStatuses(state.statuses, fresh);
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
  load().catch((err) => {
    document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
  });
  setInterval(() => void tick().catch(() => {}), TICK_MS);
});
