// Dedicated Settings window — port of macOS SettingsSceneRoot (780×720):
// icon tab bar (General / Providers / Claude Code / Display / Advanced / About)
// + card-style panes.

import { invoke } from "@tauri-apps/api/core";
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
import { settingsIcon, type SettingsIconId } from "./settings-icons";

const TAB_KEY = "birdnion.settingsSection";

type SettingsTabId =
  | "general" | "providers" | "claudeCode" | "display" | "advanced" | "about";

/** SF Symbol names from macOS SettingsTab.icon */
const TABS: { id: SettingsTabId; icon: SettingsIconId; titleKey: string }[] = [
  { id: "general", icon: "gearshape", titleKey: "settingsTabGeneral" },
  { id: "providers", icon: "square.grid.2x2", titleKey: "settingsTabProviders" },
  { id: "claudeCode", icon: "terminal", titleKey: "settingsTabClaudeCode" },
  { id: "display", icon: "eye", titleKey: "settingsTabDisplay" },
  { id: "advanced", icon: "slider.horizontal.3", titleKey: "settingsTabAdvanced" },
  { id: "about", icon: "info.circle", titleKey: "settingsTabAbout" },
];

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
 * Card = rounded 8, fill #FEFEFF, border #D7DCE2 @ 0.75, light shadow.
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
    // One remount for i18n — not a loop (listener is registered once).
    void mountSettingsWindow(onRefreshMain);
  });

  // Autostart — never block first paint if plugin is slow/unavailable.
  const autostartOn = (await invokeTimeout<boolean>("get_autostart")) ?? false;
  const autostart = switchToggle(
    autostartOn,
    (v) => { void invoke("set_autostart", { enabled: v }).catch(() => {}); },
  );

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
  // Snap to nearest known option
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
    labeledRow(t("settingsLaunchAtLogin"), t("settingsLaunchAtLoginSub"), autostart),
  ]);

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

  // Shortcut note (no global hotkey on Linux Wayland — document in-window)
  const shortcutNote = el("div", "sw-shortcut-pill",
    vi ? "Ctrl+, (trong cửa sổ chính)" : "Ctrl+, (in main window)");
  const shortcut = card(t("settingsSectionShortcut"), [
    labeledRow(t("settingsHotkey"), t("settingsHotkeySub"), shortcutNote),
  ]);

  // Quit row — macOS puts a single trailing button in an empty card.
  const quitGroup = el("div", "sw-group");
  const quitCard = el("div", "sw-card sw-card-quit");
  const quitBtn = el("button", "sw-quit-btn", t("footerQuit"));
  quitBtn.addEventListener("click", () => {
    void invoke("quit_app").catch(() => { window.close(); });
  });
  quitCard.append(quitBtn);
  quitGroup.append(quitCard);

  // Refresh now (Linux convenience; macOS uses header refresh on popover)
  const refreshNow = el("button", "sw-pill-btn", t("settingsRefreshNow"));
  refreshNow.addEventListener("click", onRefreshMain);
  const refreshCard = card(null, [
    labeledRow(t("settingsRefreshNow"), t("settingsRefreshFrequencySub"), refreshNow),
  ]);

  return page(system, usage, automation, shortcut, refreshCard, quitGroup);
}

async function displayPane(): Promise<HTMLElement> {
  const showPct = switchToggle(isShowTrayPercentEnabled(), setShowTrayPercentEnabled);
  return page(card(
    t("settingsSectionMenuBar"),
    [labeledRow(t("settingsShowTrayPercent"), t("settingsShowTrayPercentSub"), showPct)],
    t("settingsDisplayFooter"),
  ));
}

async function advancedPane(): Promise<HTMLElement> {
  const hide = switchToggle(isHidePersonalInfo(), setHidePersonalInfo);
  const storage = switchToggle(isProviderStorageEnabled(), setProviderStorageEnabledPublic);
  return page(
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
  let active = (localStorage.getItem(TAB_KEY) as SettingsTabId) || "general";
  if (!TABS.some((tab) => tab.id === active)) active = "general";

  const bar = el("nav", "sw-tabbar");
  const content = el("div", "sw-content");
  // Paint chrome immediately so the window is never a blank white sheet
  // while async panes resolve (was the "Settings trắng" bug).
  content.append(el("div", "loading", "…"));

  let paneSeq = 0;
  const renderPane = async () => {
    const seq = ++paneSeq;
    content.textContent = "";
    content.append(el("div", "loading", "…"));
    let pane: HTMLElement;
    try {
      switch (active) {
        case "general":
          pane = await generalPane(onProvidersSaved);
          break;
        case "providers":
          pane = await providersPane(onProvidersSaved);
          break;
        case "claudeCode":
          pane = await claudeCodePane(onProvidersSaved);
          break;
        case "display":
          pane = await displayPane();
          break;
        case "advanced":
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
    if (seq !== paneSeq) return; // superseded by another tab click
    content.textContent = "";
    content.append(pane);
  };

  for (const tab of TABS) {
    const btn = el("button", `sw-tab${active === tab.id ? " active" : ""}`);
    btn.dataset.tab = tab.id;
    btn.title = t(tab.titleKey);
    btn.setAttribute("aria-label", t(tab.titleKey));
    btn.append(settingsIcon(tab.icon, "sw-tab-icon"));
    btn.append(el("span", "sw-tab-label", t(tab.titleKey)));
    btn.addEventListener("click", () => {
      active = tab.id;
      localStorage.setItem(TAB_KEY, active);
      bar.querySelectorAll(".sw-tab").forEach((b) => {
        b.classList.toggle("active", (b as HTMLElement).dataset.tab === active);
      });
      void renderPane();
    });
    bar.append(btn);
  }

  root.append(bar, el("div", "sw-divider"), content);
  void renderPane(); // don't await — shell already visible
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
    // Sync paint: tab bar appears immediately, panes fill in async.
    app.append(settingsWindowRoot(onProvidersSaved));
  };
  settingsRemount = remount;
  remount();

  if (settingsMounted) return;
  settingsMounted = true;

  // Tray "Giới thiệu" / already-open settings: switch tab once (no listener stack).
  const goSection = (sec: string) => {
    if (!sec) return;
    // Same section already showing — skip full remount flash/spin.
    if (sec === localStorage.getItem(TAB_KEY) && app.querySelector(".settings-window")) return;
    localStorage.setItem(TAB_KEY, sec);
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
