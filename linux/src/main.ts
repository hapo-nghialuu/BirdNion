import { invoke } from "@tauri-apps/api/core";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard } from "./all-tab";
import { providerCard, claudeCodeQuickApplyCard, ProviderStatus } from "./provider-tab";
import { sourceChartCard } from "./source-chart";
import { adminChartCard, ClaudeAdminSnapshot } from "./admin-chart";
import { t, currentLang, setLang } from "./i18n";
import { settingsTab } from "./settings-tab";
import { getPollSeconds } from "./settings-about";

const TAB_KEY = "birdnion.selectedTab";
/** How often the tick loop runs; each provider is only re-fetched once its
 * own effective interval (override or global) has elapsed — see
 * `dueProviderIds`. 10s gives per-provider overrides reasonable resolution
 * without the fixed-cost cadence of the global setting driving every tick. */
const TICK_MS = 10_000;

type ProviderCfg = { id: string; enabled?: boolean | null; refreshInterval?: number | null; showInTray?: boolean | null };
type Settings = { version: number; providers: ProviderCfg[] };

type State = {
  claude: UsageReport | null;
  codex: UsageReport | null;
  statuses: ProviderStatus[];
  claudeAdmin: ClaudeAdminSnapshot | null;
  tab: string; // "all" | provider id
};

const state: State = {
  claude: null,
  codex: null,
  statuses: [],
  claudeAdmin: null,
  tab: localStorage.getItem(TAB_KEY) || "all",
};

/** Per-provider last-fetch timestamps (ms), used to honor `refreshInterval`
 * overrides independent of the global polling cadence. */
const lastFetched = new Map<string, number>();

/** Provider ids due for a fetch this tick: providers whose own
 * `refreshInterval` (or the global interval when unset/0) has elapsed since
 * their last fetch. Mirrors macOS `QuotaService.effectiveInterval`. */
async function dueProviderIds(): Promise<string[] | undefined> {
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

function tabsStrip(): HTMLElement {
  const strip = el("nav", "tabs");
  const addTab = (id: string, label: string) => {
    const tab = el("button", `tab${state.tab === id ? " active" : ""}`, label);
    tab.addEventListener("click", () => {
      state.tab = id;
      localStorage.setItem(TAB_KEY, id);
      render();
    });
    strip.append(tab);
  };
  addTab("all", "⊞ All");
  for (const s of state.statuses) addTab(s.id, s.displayName);
  // Language toggle + Settings pinned to the right edge of the strip.
  const lang = el("button", "tab lang-toggle", currentLang().toUpperCase());
  lang.addEventListener("click", () => {
    setLang(currentLang() === "vi" ? "en" : "vi");
    render();
  });
  strip.append(lang);
  addTab("settings", "⚙");
  return strip;
}

function render() {
  const app = document.querySelector("#app")!;
  app.textContent = "";
  // Fall back to All when the remembered provider tab disappeared.
  if (state.tab !== "all" && state.tab !== "settings"
      && !state.statuses.some((s) => s.id === state.tab)) {
    state.tab = "all";
  }
  app.append(tabsStrip());

  if (state.tab === "settings") {
    // Async view: mount a placeholder, then swap in the loaded form.
    const placeholder = el("div", "loading", "…");
    app.append(placeholder);
    void settingsTab(() => void load()).then((view) => placeholder.replaceWith(view));
    return;
  }

  if (state.tab === "all") {
    if (!state.claude && !state.codex) {
      app.append(el("div", "empty", t("noLogs")));
      return;
    }
    const combined = combine(state.claude, state.codex);
    app.append(chartCard(combined, state.claude?.hourly ?? []));
    app.append(heatmapCard(combined));
    if (combined.topModels.length > 0) app.append(topModelsCard(combined));
    return;
  }

  const status = state.statuses.find((s) => s.id === state.tab);
  if (status) {
    app.append(providerCard(status));
    void claudeCodeQuickApplyCard(status, () => {
      state.tab = "settings";
      localStorage.setItem(TAB_KEY, "settings");
      render();
    }).then((card) => { if (card) app.querySelector(".card")?.after(card); });
  }
  // Claude/Codex tabs also show their own local 30-day cost chart, matching
  // the macOS per-provider chart cards.
  if (state.tab === "claude" && state.claude) {
    app.append(sourceChartCard(state.claude, "claude"));
    if (state.claudeAdmin) app.append(adminChartCard(state.claudeAdmin));
  } else if (state.tab === "codex" && state.codex) {
    app.append(sourceChartCard(state.codex, "codex"));
  }
}

/** Fire an OS notification once per threshold crossing (macOS QuotaNotifier
 * parity): 20% remaining warns, resets once back above 25%. */
const warned = new Set<string>();
function checkQuotaWarnings(statuses: ProviderStatus[]) {
  for (const s of statuses) {
    for (const w of s.windows) {
      const key = `${s.id}:${w.label}`;
      if (w.remainingPct <= 20 && !warned.has(key)) {
        warned.add(key);
        void invoke("notify", {
          title: `BirdNion — ${s.displayName}`,
          body: `${w.label}: còn ${w.remainingPct}% quota.`,
        }).catch(() => {});
      } else if (w.remainingPct > 25) {
        warned.delete(key);
      }
    }
  }
}

/** Mirror the macOS menu-bar percent readout into the tray tooltip.
 * Providers with `showInTray === false` are skipped, mirroring macOS
 * `MenuBarVisibility`. */
function updateTrayTooltip(statuses: ProviderStatus[], hidden: Set<string>) {
  const parts = statuses
    .filter((s) => !hidden.has(s.id) && !s.error && s.windows.length > 0)
    .map((s) => {
      const lowest = s.windows.reduce((a, b) => (a.remainingPct < b.remainingPct ? a : b));
      return `${s.displayName} ${lowest.remainingPct}%`;
    });
  void invoke("set_tray_tooltip", {
    tooltip: parts.length ? parts.join(" · ") : "BirdNion",
  }).catch(() => {});
}

/** Merge freshly fetched statuses over the cached ones by id, preserving the
 * existing order/entries for providers not due this tick. */
function mergeStatuses(cached: ProviderStatus[], fresh: ProviderStatus[]): ProviderStatus[] {
  const byId = new Map(cached.map((s) => [s.id, s]));
  for (const s of fresh) byId.set(s.id, s);
  // Fresh entries not already present (new providers) are appended.
  const order = [...cached.map((s) => s.id)];
  for (const s of fresh) if (!order.includes(s.id)) order.push(s.id);
  return order.map((id) => byId.get(id)!).filter(Boolean);
}

async function fetchTrayHidden(): Promise<Set<string>> {
  const settings = await invoke<Settings>("get_settings").catch(() => null);
  if (!settings) return new Set();
  return new Set(settings.providers.filter((p) => p.showInTray === false).map((p) => p.id));
}

/** Initial full load (all enabled providers) plus the local usage reports. */
async function load() {
  const [claude, codex, statuses, claudeAdmin] = await Promise.all([
    invoke<UsageReport | null>("claude_usage_report").catch(() => null),
    invoke<UsageReport | null>("codex_usage_report").catch(() => null),
    invoke<ProviderStatus[]>("provider_statuses", { ids: null }).catch(() => [] as ProviderStatus[]),
    invoke<ClaudeAdminSnapshot | null>("claude_admin_usage").catch(() => null),
  ]);
  const now = Date.now();
  for (const s of statuses) lastFetched.set(s.id, now);
  state.claude = claude;
  state.codex = codex;
  state.statuses = statuses;
  state.claudeAdmin = claudeAdmin;
  checkQuotaWarnings(statuses);
  updateTrayTooltip(statuses, await fetchTrayHidden());
  render();
}

/** Tick: only re-fetch providers whose own effective interval elapsed,
 * merging fresh results over the cached state so unaffected tabs don't
 * flicker back to "loading". */
async function tick() {
  const ids = await dueProviderIds();
  if (!ids || ids.length === 0) return;
  const fresh = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
  const now = Date.now();
  for (const s of fresh) lastFetched.set(s.id, now);
  state.statuses = mergeStatuses(state.statuses, fresh);
  checkQuotaWarnings(state.statuses);
  updateTrayTooltip(state.statuses, await fetchTrayHidden());
  render();
}

/** Ctrl+, switches to the Settings tab (in-window only — no global OS
 * shortcut, since Wayland global-shortcut support is inconsistent). */
window.addEventListener("keydown", (ev) => {
  if (ev.ctrlKey && ev.key === ",") {
    ev.preventDefault();
    state.tab = "settings";
    localStorage.setItem(TAB_KEY, "settings");
    render();
  }
});

window.addEventListener("DOMContentLoaded", () => {
  load().catch((err) => {
    document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
  });
  setInterval(() => void tick().catch(() => {}), TICK_MS);
});
