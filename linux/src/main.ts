import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard } from "./all-tab";
import { providerCard, claudeCodeQuickApplyCard, loadingSkeleton, ProviderStatus } from "./provider-tab";
import { freemodelAccountsPopoverCard } from "./freemodel-accounts-popover";
import { elevenlabsKeysPopoverCard } from "./elevenlabs-keys-popover";
import { codexAccountsPopoverCard } from "./codex-accounts-popover";
import { NAME_BY_ID, PROVIDERS_CHANGED_EVENT } from "./settings-tab";
import { sourceChartCard } from "./source-chart";
import { adminChartCard, ClaudeAdminSnapshot } from "./admin-chart";
import { t } from "./i18n";
import {
  getPollSeconds, isManualRefresh, isRefreshOnOpenEnabled, effectiveQuotaWarn,
  isShowTrayPercentEnabled,
} from "./settings-about";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { LogicalSize, PhysicalSize } from "@tauri-apps/api/dpi";
import { logoMark, logoUrl, providerTintCss } from "./logos";
import { mountSettingsWindow } from "./settings-window";
import { settingsIcon } from "./settings-icons";
import { initTheme } from "./theme";

/** Popover width — matches macOS panelWidth / ProviderTabs density. */
const POPOVER_WIDTH = 420;
/** Hard height cap (macOS AppDelegate.maxPanelHeight = 640). All-tab scrolls. */
const POPOVER_MAX_HEIGHT = 640;
const POPOVER_MIN_HEIGHT = 220;
/** Extra logical px so the footer is never clipped under the cap. */
const FIT_SAFETY_PX = 18;

const TAB_KEY = "birdnion.selectedTab";
/** How often the tick loop runs; each provider is only re-fetched once its
 * own effective interval (override or global) has elapsed — see
 * `dueProviderIds`. 10s gives per-provider overrides reasonable resolution
 * without the fixed-cost cadence of the global setting driving every tick. */
const TICK_MS = 10_000;

type ProviderCfg = {
  id: string; enabled?: boolean | null; refreshInterval?: number | null;
  showInTray?: boolean | null; displayName?: string | null;
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
    const intervalMs = p.refreshInterval && p.refreshInterval > 0 ? p.refreshInterval * 1000 : globalMs;
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

/** macOS BirdNionHeader remake: logo + title + status pill + refresh + settings. */
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

  const settingsBtn = document.createElement("button");
  settingsBtn.type = "button";
  settingsBtn.className = "header-refresh header-settings";
  settingsBtn.title = t("footerSettings");
  settingsBtn.setAttribute("aria-label", t("footerSettings"));
  settingsBtn.append(settingsIcon("gearshape", "header-refresh-icon"));
  settingsBtn.addEventListener("click", () => openSettings("general"));

  actions.append(refresh, settingsBtn);
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

  const addIconTab = (id: string, label: string, mark: Element) => {
    const active = state.tab === id;
    // Compact (d2852ed4): unselected = logo-only; selected = logo + name.
    const tab = el("button", active ? "tab tab-pill tab-icon active" : "tab tab-pill tab-icon");
    tab.title = label;
    tab.setAttribute("aria-label", label);
    tab.append(mark);
    if (active) tab.append(el("span", "tab-pill-label", label));
    tab.addEventListener("click", () => goTab(id));
    strip.append(tab);
  };

  // All = SF square.grid.2x2.fill (macOS allChip)
  // Text-only All pill (no logo) — macOS allChip.
  {
    const allActive = state.tab === "all";
    const allTab = el("button", allActive ? "tab tab-pill active" : "tab tab-pill");
    allTab.title = t("tabAll");
    allTab.setAttribute("aria-label", t("tabAll"));
    allTab.append(el("span", "tab-pill-label", t("tabAll")));
    allTab.addEventListener("click", () => goTab("all"));
    strip.append(allTab);
  }

  for (const s of state.statuses) {
    const active = state.tab === s.id;
    const mark = logoMark(s.id, active ? "tab-logo-mono tab-logo-on-accent" : "tab-logo-mono");
    if (!active) {
      // Brand tint on idle chips (macOS providerTint); falls back to secondary.
      const tint = providerTintCss(s.id);
      if (tint) mark.style.setProperty("--tab-tint", tint);
    }
    addIconTab(s.id, s.displayName, mark);
  }

  return strip;
}

/** Compact footer (macOS ActionsList remake): "Updated …" left + icon buttons right. */
function popoverFooter(): HTMLElement {
  const foot = el("footer", "popover-footer footer-compact");

  // Most recent provider lastUpdated across live statuses.
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
  const mk = (
    iconId: "gearshape" | "info.circle" | "power",
    label: string,
    extraClass: string,
    onClick: () => void,
  ) => {
    const btn = el("button", `footer-icon-btn${extraClass ? ` ${extraClass}` : ""}`);
    btn.title = label;
    btn.setAttribute("aria-label", label);
    btn.append(settingsIcon(iconId, "footer-icon-svg"));
    btn.addEventListener("click", onClick);
    return btn;
  };
  actions.append(
    mk("gearshape", t("footerSettings"), "", () => openSettings("general")),
    mk("info.circle", t("footerAbout"), "", () => openSettings("about")),
    mk("power", t("footerQuit"), "quit", () => {
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

  // .container padding 8 top + 10 bottom; three 7px gaps between 4 sections.
  const padY = 8 + 10;
  const gaps = 7 * 3;
  let sum = padY + gaps;
  for (const el of [header, tabs, body, footer]) {
    if (!el) continue;
    // scrollHeight catches overflow children; rect is laid-out size.
    sum += Math.max(el.scrollHeight, el.getBoundingClientRect().height);
  }

  const whole = Math.max(app.scrollHeight, app.getBoundingClientRect().height);
  return Math.max(sum, whole);
}

/**
 * Resize the main popover to hug its content (macOS DropdownPanel fittingSize).
 *
 * No internal scrollbar on normal tabs. `setSize` is the **outer** window
 * (includes title-bar chrome), so we add outer−inner and then verify the
 * footer is fully inside `window.innerHeight`.
 */
async function fitMainWindowToContent() {
  if (isSettingsWindow()) return;
  const app = document.querySelector("#app") as HTMLElement | null;
  if (!app) return;

  document.documentElement.classList.remove("popover-capped");
  document.body.classList.remove("popover-capped");

  const natural = measurePopoverContentHeight(app);
  if (natural < 80) return;

  const contentH = Math.ceil(natural + FIT_SAFETY_PX);
  const win = getCurrentWindow();

  // Outer − inner = title bar / borders (logical px). setSize uses outer size.
  let chromeLogical = 0;
  let scale = 1;
  try {
    scale = await win.scaleFactor();
    const outer = await win.outerSize();
    const inner = await win.innerSize();
    if (outer.height > 0 && inner.height > 0 && outer.height >= inner.height) {
      chromeLogical = (outer.height - inner.height) / scale;
    }
  } catch {
    // mock / first paint — assume a typical macOS titlebar if decorated.
    chromeLogical = 28;
  }

  const screenCap = typeof window.screen?.availHeight === "number"
    ? Math.floor(window.screen.availHeight * 0.95)
    : POPOVER_MAX_HEIGHT;
  const maxOuter = Math.min(POPOVER_MAX_HEIGHT + chromeLogical, screenCap);
  let outerH = Math.ceil(contentH + chromeLogical);
  outerH = Math.max(POPOVER_MIN_HEIGHT + chromeLogical, Math.min(maxOuter, outerH));

  try {
    await win.setSize(new LogicalSize(POPOVER_WIDTH, outerH));
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
      scale = await win.scaleFactor();
      const outer = await win.outerSize();
      const growPx = Math.ceil(clip * scale) + Math.ceil(6 * scale);
      await win.setSize(new PhysicalSize(outer.width, outer.height + growPx));
    } catch {
      break;
    }
  }

  app.style.height = "";
  // Scroll only if content truly exceeds the screen cap (rare).
  const capped = contentH + chromeLogical > maxOuter;
  document.documentElement.classList.toggle("popover-capped", capped);
  document.body.classList.toggle("popover-capped", capped);
}

function scheduleFitWindow() {
  if (isSettingsWindow()) return;
  // Double rAF: wait for layout after DOM paint (logos, fonts, charts).
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      void fitMainWindowToContent();
      // Logos may load late and change measured height — re-fit once.
      document.querySelectorAll("#app img").forEach((node) => {
        const img = node as HTMLImageElement;
        if (!img.complete) {
          img.addEventListener("load", () => { void fitMainWindowToContent(); }, { once: true });
        }
      });
    });
  });
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
      body.append(chartCard(combined, state.claude?.hourly ?? []));
      body.append(heatmapCard(combined));
      if (combined.topModels.length > 0) body.append(topModelsCard(combined));
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
  return trayPercents(s)
    .map((p) => `${clampPct(p)}%`)
    .join("  ");
}

/** FreeModel: the bonus "Số dư" window stays out of the tray (not a rate
 * window). Once the 5-hour window is exhausted and bonus balance remains,
 * the readout collapses to JUST the balance percent — credits apply
 * automatically at that point (macOS `freemodelMenuBarPercents` parity).
 * Other providers: all windows. */
function trayPercents(s: ProviderStatus): number[] {
  if (s.id !== "freemodel") return s.windows.map((w) => w.remainingPct);
  const balance = s.windows.find((w) => w.label === "Số dư");
  const fiveH = s.windows.find((w) => w.label === "5 giờ");
  if (fiveH && fiveH.remainingPct <= 0 && balance && balance.remainingPct > 0) {
    return [balance.remainingPct];
  }
  const out = s.windows.filter((w) => w.label !== "Số dư").map((w) => w.remainingPct);
  if (out.length === 0 && balance) return [balance.remainingPct];
  return out;
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
 */
function buildTrayFrames(statuses: ProviderStatus[], hidden: Set<string>): Omit<TrayFrame, "iconPng">[] {
  if (!isShowTrayPercentEnabled()) return [];
  return statuses
    .filter((s) => !hidden.has(s.id) && !s.error && s.windows.length > 0)
    .map((s) => {
      const lowest = s.windows.reduce((a, b) => (a.remainingPct < b.remainingPct ? a : b));
      return {
        providerId: s.id,
        percentText: trayPercentText(s),
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
  const built = buildTrayFrames(statuses, hidden);
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

/** Merge freshly fetched statuses over the cached ones by id, preserving the
 * **cached order** (which is settings.providers order via seed/rebuild).
 * New ids not yet in cache are appended. */
function mergeStatuses(cached: ProviderStatus[], fresh: ProviderStatus[]): ProviderStatus[] {
  const byId = new Map(cached.map((s) => [s.id, s]));
  for (const s of fresh) byId.set(s.id, s);
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
    if (!keep.has(id)) lastFetched.delete(id);
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
async function load() {
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
    const publishStatuses = (fresh: ProviderStatus[]) => {
      const prevIds = state.statuses.map((s) => s.id).join(",");
      const now = Date.now();
      for (const s of fresh) lastFetched.set(s.id, now);
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
            .then(publishStatuses)))
      : invoke<ProviderStatus[]>("provider_statuses", { ids: null })
          .catch(() => [] as ProviderStatus[])
          .then(publishStatuses)
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
  if (fresh.length === 0) return;
  lastFetched.set(id, Date.now());
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
  const ids = await dueProviderIds();
  if (!ids || ids.length === 0) return;
  const prevIds = state.statuses.map((s) => s.id).join(",");
  const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
  const now = Date.now();
  for (const s of fresh) lastFetched.set(s.id, now);
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
  await load();
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
