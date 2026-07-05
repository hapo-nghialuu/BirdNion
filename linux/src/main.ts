import { invoke } from "@tauri-apps/api/core";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard } from "./all-tab";
import { providerCard, claudeCodeQuickApplyCard, ProviderStatus } from "./provider-tab";
import { sourceChartCard } from "./source-chart";
import { adminChartCard, ClaudeAdminSnapshot } from "./admin-chart";
import { t, currentLang, setLang } from "./i18n";
import { settingsTab } from "./settings-tab";

const TAB_KEY = "birdnion.selectedTab";
const REFRESH_MS = 120_000;

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

/** Mirror the macOS menu-bar percent readout into the tray tooltip. */
function updateTrayTooltip(statuses: ProviderStatus[]) {
  const parts = statuses
    .filter((s) => !s.error && s.windows.length > 0)
    .map((s) => {
      const lowest = s.windows.reduce((a, b) => (a.remainingPct < b.remainingPct ? a : b));
      return `${s.displayName} ${lowest.remainingPct}%`;
    });
  void invoke("set_tray_tooltip", {
    tooltip: parts.length ? parts.join(" · ") : "BirdNion",
  }).catch(() => {});
}

async function load() {
  const [claude, codex, statuses, claudeAdmin] = await Promise.all([
    invoke<UsageReport | null>("claude_usage_report").catch(() => null),
    invoke<UsageReport | null>("codex_usage_report").catch(() => null),
    invoke<ProviderStatus[]>("provider_statuses").catch(() => [] as ProviderStatus[]),
    invoke<ClaudeAdminSnapshot | null>("claude_admin_usage").catch(() => null),
  ]);
  state.claude = claude;
  state.codex = codex;
  state.statuses = statuses;
  state.claudeAdmin = claudeAdmin;
  checkQuotaWarnings(statuses);
  updateTrayTooltip(statuses);
  render();
}

window.addEventListener("DOMContentLoaded", () => {
  load().catch((err) => {
    document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
  });
  setInterval(() => void load().catch(() => {}), REFRESH_MS);
});
