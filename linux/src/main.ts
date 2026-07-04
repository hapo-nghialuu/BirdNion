import { invoke } from "@tauri-apps/api/core";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard } from "./all-tab";
import { providerCard, ProviderStatus } from "./provider-tab";
import { sourceChartCard } from "./source-chart";
import { t, currentLang, setLang } from "./i18n";

const TAB_KEY = "birdnion.selectedTab";
const REFRESH_MS = 120_000;

type State = {
  claude: UsageReport | null;
  codex: UsageReport | null;
  statuses: ProviderStatus[];
  tab: string; // "all" | provider id
};

const state: State = {
  claude: null,
  codex: null,
  statuses: [],
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
  // Language toggle pinned to the right edge of the strip.
  const lang = el("button", "tab lang-toggle", currentLang().toUpperCase());
  lang.addEventListener("click", () => {
    setLang(currentLang() === "vi" ? "en" : "vi");
    render();
  });
  strip.append(lang);
  return strip;
}

function render() {
  const app = document.querySelector("#app")!;
  app.textContent = "";
  // Fall back to All when the remembered provider tab disappeared.
  if (state.tab !== "all" && !state.statuses.some((s) => s.id === state.tab)) {
    state.tab = "all";
  }
  app.append(tabsStrip());

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
  }
  // Claude/Codex tabs also show their own local 30-day cost chart, matching
  // the macOS per-provider chart cards.
  if (state.tab === "claude" && state.claude) {
    app.append(sourceChartCard(state.claude, "claude"));
  } else if (state.tab === "codex" && state.codex) {
    app.append(sourceChartCard(state.codex, "codex"));
  }
}

async function load() {
  const [claude, codex, statuses] = await Promise.all([
    invoke<UsageReport | null>("claude_usage_report").catch(() => null),
    invoke<UsageReport | null>("codex_usage_report").catch(() => null),
    invoke<ProviderStatus[]>("provider_statuses").catch(() => [] as ProviderStatus[]),
  ]);
  state.claude = claude;
  state.codex = codex;
  state.statuses = statuses;
  render();
}

window.addEventListener("DOMContentLoaded", () => {
  load().catch((err) => {
    document.querySelector("#app")!.textContent = `${t("loadError")}: ${err}`;
  });
  setInterval(() => void load().catch(() => {}), REFRESH_MS);
});
