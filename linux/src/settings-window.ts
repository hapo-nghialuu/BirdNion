// Dedicated Settings window — port of macOS SettingsSceneRoot (920×620):
// vertical sidebar (General / Providers / Claude Code / Advanced / About)
// + card-style panes. Display folded into General; Debug into Advanced.

import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import { t, currentLang, setLang, type Lang } from "./i18n";
import {
  getPollSeconds, setPollSeconds, isManualRefresh, isRefreshOnOpenEnabled,
  setRefreshOnOpenEnabledPublic, isProviderStorageEnabled, setProviderStorageEnabledPublic,
  isStatusChecksEnabled, setStatusChecksEnabled,
  isSessionNotifyEnabled, setSessionNotifyEnabled,
  isQuotaWarnEnabled, setQuotaWarnEnabled,
  getQuotaWarnL1, setQuotaWarnL1, getQuotaWarnL2, setQuotaWarnL2,
  isShowTrayPercentEnabled, setShowTrayPercentEnabled,
  isHidePersonalInfo, setHidePersonalInfo,
  REFRESH_OPTIONS, aboutSection,
} from "./settings-about";
import { providersPane } from "./settings-tab";
import { claudeCodePane } from "./claude-code-pane";
import { isClaudeCodeSupported } from "./claude-code";
import { settingsIcon, type SettingsIconId } from "./settings-icons";
import { getAppearance, setAppearance, type Appearance } from "./theme";

const TAB_KEY = "birdnion.settingsSection";

type SettingsTabId =
  | "general" | "providers" | "claudeCode" | "advanced" | "about"
  // legacy ids still routed from tray / older localStorage
  | "display" | "debug";

type NavItem = {
  id: SettingsTabId;
  icon: SettingsIconId;
  titleKey: string;
  iconBg: string;
};

/** Five sidebar items — Display→General, Debug→Advanced (macOS P2). */
const NAV: NavItem[] = [
  { id: "general", icon: "gearshape", titleKey: "settingsTabGeneral", iconBg: "#8C8C94" },
  { id: "providers", icon: "square.grid.2x2", titleKey: "settingsTabProviders", iconBg: "#2563EB" },
  { id: "claudeCode", icon: "terminal", titleKey: "settingsTabClaudeCode", iconBg: "#8C59D9" },
  { id: "advanced", icon: "slider.horizontal.3", titleKey: "settingsTabAdvanced", iconBg: "#8C8C94" },
  { id: "about", icon: "info.circle", titleKey: "settingsTabAbout", iconBg: "#33A659" },
];

function normalizeTab(id: string | null): SettingsTabId {
  if (id === "display") return "general";
  if (id === "debug") return "advanced";
  if (NAV.some((n) => n.id === id)) return id as SettingsTabId;
  return "general";
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function switchToggle(checked: boolean, onChange: (v: boolean) => void): HTMLInputElement {
  const input = document.createElement("input");
  input.type = "checkbox";
  input.className = "sw-switch";
  input.checked = checked;
  input.addEventListener("change", () => onChange(input.checked));
  return input;
}

function labeledRow(
  title: string,
  subtitle: string,
  control: HTMLElement,
): HTMLElement {
  const row = el("div", "sw-row");
  const text = el("div", "sw-row-text");
  text.append(el("div", "sw-row-title", title));
  if (subtitle) text.append(el("div", "sw-row-sub", subtitle));
  row.append(text, control);
  return row;
}

/**
 * macOS SettingsCard: section header sits OUTSIDE the white card.
 */
function card(header: string | null, rows: HTMLElement[], footer?: string): HTMLElement {
  const group = el("div", "sw-group");
  if (header) group.append(el("div", "sw-section-header", header.toUpperCase()));
  const c = el("div", "sw-card");
  const body = el("div", "sw-card-body");
  rows.forEach((r, i) => {
    if (i > 0) body.append(el("div", "sw-row-divider"));
    body.append(r);
  });
  c.append(body);
  group.append(c);
  if (footer) group.append(el("div", "sw-card-footer-note", footer));
  return group;
}

function paneHeader(title: string, subtitle?: string): HTMLElement {
  const h = el("div", "sw-pane-header");
  h.append(el("div", "sw-pane-title", title));
  if (subtitle) h.append(el("div", "sw-pane-subtitle", subtitle));
  return h;
}

function page(...children: HTMLElement[]): HTMLElement {
  const p = el("div", "settings-page");
  for (const c of children) p.append(c);
  return p;
}

// --- Panes ----------------------------------------------------------------

/** Invoke with a short timeout so a hung Tauri command never blanks Settings. */
async function invokeTimeout<T>(cmd: string, args: Record<string, unknown> = {}, ms = 1200): Promise<T | null> {
  try {
    return await Promise.race([
      invoke<T>(cmd, args),
      new Promise<null>((resolve) => setTimeout(() => resolve(null), ms)),
    ]);
  } catch {
    return null;
  }
}

async function generalPane(onRefreshMain: () => void): Promise<HTMLElement> {
  const vi = currentLang() === "vi";

  // Language
  const langSelect = document.createElement("select");
  langSelect.className = "sw-select";
  for (const [val, label] of [["vi", "Tiếng Việt"], ["en", "English"]] as const) {
    const o = document.createElement("option");
    o.value = val;
    o.textContent = label;
    langSelect.append(o);
  }
  langSelect.value = currentLang();
  langSelect.addEventListener("change", () => {
    setLang(langSelect.value as Lang);
    void mountSettingsWindow(onRefreshMain);
  });

  // Appearance — light | dark | auto
  const appearanceSelect = document.createElement("select");
  appearanceSelect.className = "sw-select";
  for (const [val, labelKey] of [
    ["light", "settingsAppearanceLight"],
    ["dark", "settingsAppearanceDark"],
    ["auto", "settingsAppearanceAuto"],
  ] as const) {
    const o = document.createElement("option");
    o.value = val;
    o.textContent = t(labelKey);
    appearanceSelect.append(o);
  }
  appearanceSelect.value = getAppearance();
  appearanceSelect.addEventListener("change", () => {
    setAppearance(appearanceSelect.value as Appearance);
  });

  // Autostart — never block first paint if plugin is slow/unavailable.
  const autostartOn = (await invokeTimeout<boolean>("get_autostart")) ?? false;
  const autostart = switchToggle(
    autostartOn,
    (v) => { void invoke("set_autostart", { enabled: v }).catch(() => {}); },
  );

  // Menu bar % (folded from Display pane)
  const showPct = switchToggle(isShowTrayPercentEnabled(), setShowTrayPercentEnabled);

  // Refresh frequency picker
  const freq = document.createElement("select");
  freq.className = "sw-select";
  const current = getPollSeconds();
  for (const opt of REFRESH_OPTIONS) {
    const o = document.createElement("option");
    o.value = String(opt.value);
    o.textContent = vi ? opt.vi : opt.en;
    freq.append(o);
  }
  const known = REFRESH_OPTIONS.map((o) => o.value);
  freq.value = String(known.includes(current) ? current : 120);
  freq.addEventListener("change", () => setPollSeconds(Number(freq.value)));

  const refreshOnOpen = switchToggle(isRefreshOnOpenEnabled(), setRefreshOnOpenEnabledPublic);
  const statusChecks = switchToggle(isStatusChecksEnabled(), setStatusChecksEnabled);
  const sessionNotify = switchToggle(isSessionNotifyEnabled(), setSessionNotifyEnabled);
  const quotaWarn = switchToggle(isQuotaWarnEnabled(), (v) => {
    setQuotaWarnEnabled(v);
    void mountSettingsWindow(onRefreshMain);
  });

  const system = card(t("settingsSectionSystem"), [
    labeledRow(t("settingsLanguage"), t("settingsLanguageSub"), langSelect),
    labeledRow(t("settingsAppearance"), t("settingsAppearanceSub"), appearanceSelect),
    labeledRow(t("settingsShowTrayPercent"), t("settingsShowTrayPercentSub"), showPct),
    labeledRow(t("settingsLaunchAtLogin"), t("settingsLaunchAtLoginSub"), autostart),
  ], t("settingsDisplayFooter"));

  const usageRows = [
    labeledRow(t("settingsRefreshFrequency"), t("settingsRefreshFrequencySub"), freq),
    labeledRow(t("settingsRefreshOnOpen"), t("settingsRefreshOnOpenSub"), refreshOnOpen),
  ];
  const usage = card(
    t("settingsSectionUsage"),
    usageRows,
    isManualRefresh() ? t("settingsGlobalPollingManualHint") : undefined,
  );

  const autoRows = [
    labeledRow(t("settingsStatusChecks"), t("settingsStatusChecksSub"), statusChecks),
    labeledRow(t("settingsSessionNotify"), t("settingsSessionNotifySub"), sessionNotify),
    labeledRow(t("settingsQuotaWarn"), t("settingsQuotaWarnSub"), quotaWarn),
  ];
  if (isQuotaWarnEnabled()) {
    const l1 = document.createElement("input");
    l1.type = "number";
    l1.min = "5";
    l1.max = "95";
    l1.step = "5";
    l1.className = "sw-input-num";
    l1.value = String(getQuotaWarnL1());
    l1.addEventListener("change", () => setQuotaWarnL1(Number(l1.value) || 50));
    const l2 = document.createElement("input");
    l2.type = "number";
    l2.min = "1";
    l2.max = "90";
    l2.step = "5";
    l2.className = "sw-input-num";
    l2.value = String(getQuotaWarnL2());
    l2.addEventListener("change", () => setQuotaWarnL2(Number(l2.value) || 20));
    autoRows.push(
      labeledRow(t("settingsWarnThreshold"), t("settingsWarnThresholdSub"), l1),
      labeledRow(t("settingsCriticalThreshold"), t("settingsCriticalThresholdSub"), l2),
    );
  }
  const automation = card(t("settingsSectionAutomation"), autoRows);

  const shortcutNote = el("div", "sw-shortcut-pill",
    vi ? "Ctrl+, (trong cửa sổ chính)" : "Ctrl+, (in main window)");
  const shortcut = card(t("settingsSectionShortcut"), [
    labeledRow(t("settingsHotkey"), t("settingsHotkeySub"), shortcutNote),
  ]);

  const quitGroup = el("div", "sw-group");
  const quitCard = el("div", "sw-card sw-card-quit");
  const quitBtn = el("button", "sw-quit-btn", t("footerQuit"));
  quitBtn.addEventListener("click", () => {
    void invoke("quit_app").catch(() => { window.close(); });
  });
  quitCard.append(quitBtn);
  quitGroup.append(quitCard);

  const refreshNow = el("button", "sw-pill-btn", t("settingsRefreshNow"));
  refreshNow.addEventListener("click", onRefreshMain);
  const refreshCard = card(null, [
    labeledRow(t("settingsRefreshNow"), t("settingsRefreshFrequencySub"), refreshNow),
  ]);

  return page(
    paneHeader(t("settingsTabGeneral"), t("settingsGeneralSubtitle")),
    system, usage, automation, shortcut, refreshCard, quitGroup,
  );
}

async function advancedPane(): Promise<HTMLElement> {
  const hide = switchToggle(isHidePersonalInfo(), setHidePersonalInfo);
  const storage = switchToggle(isProviderStorageEnabled(), setProviderStorageEnabledPublic);
  return page(
    paneHeader(t("settingsTabAdvanced"), t("settingsAdvancedSubtitle")),
    card(t("settingsSectionPrivacy"), [
      labeledRow(t("settingsHidePersonal"), t("settingsHidePersonalSub"), hide),
    ]),
    card(t("settingsSectionDeveloper"), [
      labeledRow(t("settingsProviderStorage"), t("settingsProviderStorageSub"), storage),
    ], t("settingsDeveloperFooter")),
  );
}

// --- Root -----------------------------------------------------------------

export function settingsWindowRoot(onProvidersSaved: () => void): HTMLElement {
  const root = el("div", "settings-window");
  let active = normalizeTab(localStorage.getItem(TAB_KEY));
  let searchQuery = "";
  /** Providers with a non-empty API key (macOS SettingsSidebar.providersWithKey). */
  let providersWithKey = 0;
  /** Active AI agents, max 2: Codex active + any Claude Code on/synced. */
  let activeAgentCount = 0;
  let badgeSeq = 0;

  const sidebar = el("aside", "sw-sidebar");
  const nav = el("nav", "sw-sidebar-nav");
  const content = el("div", "sw-content");
  content.append(el("div", "loading", "…"));

  // Search filters nav titles only (KISS — plan unresolved Q#2).
  const searchWrap = el("div", "sw-sidebar-search");
  searchWrap.append(el("span", "sw-sidebar-search-icon", "⌕"));
  const searchInput = document.createElement("input");
  searchInput.type = "search";
  searchInput.className = "sw-sidebar-search-input";
  searchInput.placeholder = t("settingsSidebarSearch");
  searchInput.value = searchQuery;
  searchInput.addEventListener("input", () => {
    searchQuery = searchInput.value;
    renderNav();
  });
  searchWrap.append(searchInput);

  const footer = el("div", "sw-sidebar-footer", "BirdNion");
  void getVersion().then((v) => {
    footer.textContent = v ? `BirdNion ${v}` : "BirdNion";
  }).catch(() => {});

  // Contextual roster slot below the nav (macOS c993e80a): Providers /
  // AI Coding embed their list here; the content column keeps only the detail.
  const extra = el("div", "sw-sidebar-extra");

  type SettingsSnap = {
    providers?: Array<{ id: string; apiKey?: string | null }>;
    claudeCodeProfiles?: Array<{ id: string }>;
  };

  /** macOS SettingsSidebar.refreshBadges — async, then re-paint nav pills. */
  const refreshBadges = async () => {
    const seq = ++badgeSeq;
    const settings = await invokeTimeout<SettingsSnap>("get_settings", {}, 2000);
    if (seq !== badgeSeq) return;

    const providers = settings?.providers ?? [];
    providersWithKey = providers.filter((p) => !!(p.apiKey ?? "").trim()).length;

    let agents = 0;
    const codexActive = await invokeTimeout<string | null>("codex_active_id", {}, 1500);
    if (seq !== badgeSeq) return;
    if (codexActive) agents += 1;

    let claudeOn = false;
    // Prefer state commands already on the wire — stop at first "on".
    // Only Claude Code-capable backends with a key (macOS isFullyConfigured gate).
    for (const p of providers) {
      if (!isClaudeCodeSupported(p.id) || !(p.apiKey ?? "").trim()) continue;
      const st = await invokeTimeout<{ state: string }>(
        "claude_code_state",
        { providerId: p.id },
        800,
      );
      if (seq !== badgeSeq) return;
      if (st?.state === "on") {
        claudeOn = true;
        break;
      }
    }
    if (!claudeOn) {
      for (const p of settings?.claudeCodeProfiles ?? []) {
        const st = await invokeTimeout<{ state: string }>(
          "claude_code_profile_state",
          { profileId: p.id },
          800,
        );
        if (seq !== badgeSeq) return;
        if (st?.state === "on") {
          claudeOn = true;
          break;
        }
      }
    }
    if (claudeOn) agents += 1;
    activeAgentCount = agents;
    renderNav();
  };

  let paneSeq = 0;
  const renderPane = async () => {
    const seq = ++paneSeq;
    content.textContent = "";
    content.append(el("div", "loading", "…"));
    let pane: HTMLElement;
    try {
      switch (active) {
        case "general":
        case "display":
          pane = await generalPane(onProvidersSaved);
          break;
        case "providers":
          pane = await providersPane(onProvidersSaved);
          break;
        case "claudeCode":
          pane = await claudeCodePane(onProvidersSaved);
          break;
        case "advanced":
        case "debug":
          pane = await advancedPane();
          break;
        case "about":
          pane = await aboutSection();
          break;
        default:
          pane = el("div", "empty", "—");
      }
    } catch (err) {
      pane = el("div", "empty", `${t("loadError")}: ${err}`);
    }
    if (seq !== paneSeq) return;
    extra.textContent = "";
    extra.classList.remove("visible");
    // Moving the node keeps the pane's listeners + closure refs intact, so
    // its internal re-renders keep targeting the same (now embedded) element.
    const roster = pane.querySelector(".pp-sidebar");
    if (roster && (active === "providers" || active === "claudeCode")) {
      extra.append(roster);
      extra.classList.add("visible");
    }
    content.textContent = "";
    content.append(pane);
    // Re-count badges after pane work (activate/deactivate may have changed).
    void refreshBadges();
  };

  const setActive = (id: SettingsTabId) => {
    active = normalizeTab(id);
    localStorage.setItem(TAB_KEY, active);
    renderNav();
    void renderPane();
  };

  const badgeText = (id: SettingsTabId): string | null => {
    if (id === "providers") return providersWithKey > 0 ? String(providersWithKey) : null;
    if (id === "claudeCode") return activeAgentCount > 0 ? `${activeAgentCount} ON` : null;
    return null;
  };

  const renderNav = () => {
    nav.textContent = "";
    const q = searchQuery.trim().toLowerCase();
    const items = NAV.filter((item) => {
      if (!q) return true;
      return t(item.titleKey).toLowerCase().includes(q);
    });
    for (const item of items) {
      const btn = el("button", `sw-nav-row${active === item.id ? " active" : ""}`);
      btn.dataset.tab = item.id;
      btn.title = t(item.titleKey);
      btn.setAttribute("aria-label", t(item.titleKey));
      const tile = el("span", "sw-nav-icon-tile");
      tile.style.background = item.iconBg;
      tile.append(settingsIcon(item.icon, "sw-tab-icon"));
      btn.append(tile);
      btn.append(el("span", "sw-nav-label", t(item.titleKey)));
      const badge = badgeText(item.id);
      if (badge) btn.append(el("span", "sw-nav-badge", badge));
      btn.addEventListener("click", () => setActive(item.id));
      nav.append(btn);
    }
  };

  sidebar.append(searchWrap, nav, extra, footer);
  root.append(sidebar, content);
  renderNav();
  void refreshBadges();
  void renderPane();
  return root;
}

/** Guard: mountSettingsWindow used to re-bind listeners every call → remount storm. */
let settingsMounted = false;
let settingsRemount: (() => void) | null = null;

/** Full-document mount for the settings webview. */
export async function mountSettingsWindow(onProvidersSaved: () => void = () => {}) {
  window.__BIRDNION_MODE__ = "settings";
  document.body.classList.add("settings-body-root");
  const app = document.querySelector("#app");
  if (!app) return;

  const remount = () => {
    app.className = "settings-root-container";
    app.textContent = "";
    app.append(settingsWindowRoot(onProvidersSaved));
  };
  settingsRemount = remount;
  remount();

  if (settingsMounted) return;
  settingsMounted = true;

  const goSection = (sec: string) => {
    if (!sec) return;
    const normalized = normalizeTab(sec);
    if (normalized === localStorage.getItem(TAB_KEY) && app.querySelector(".settings-window")) return;
    localStorage.setItem(TAB_KEY, normalized);
    settingsRemount?.();
  };
  window.addEventListener("birdnion-settings-section", ((ev: CustomEvent<string>) => {
    if (ev.detail) goSection(ev.detail);
  }) as EventListener);
  try {
    const { listen } = await import("@tauri-apps/api/event");
    await listen<string>("open-settings-section", (ev) => {
      if (ev.payload) goSection(ev.payload);
    });
  } catch { /* browser mock */ }
}
