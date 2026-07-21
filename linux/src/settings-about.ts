// About section + global polling-interval control at the bottom of Settings.
// The polling interval persists in localStorage (read by main.ts's tick
// loop) rather than settings.json, since it's a local UI preference, not a
// shared provider config value.

import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t } from "./i18n";

const UPDATE_CHANNEL_KEY = "birdnion.updateChannel";

type UpdateInfo = { version: string; url: string };

/** Update channel: "stable" (default) skips prereleases, "beta" includes
 * them. Mirrors macOS `updateChannel` UserDefaults key. */
function getUpdateChannel(): "stable" | "beta" {
  return localStorage.getItem(UPDATE_CHANNEL_KEY) === "beta" ? "beta" : "stable";
}

const POLL_KEY = "birdnion.pollSeconds";
const POLL_DEFAULT = 120;
const POLL_MANUAL = 0;
const POLL_MIN = 30;
/** Allow 1h to match macOS RefreshFrequency.oneHour. */
const POLL_MAX = 3600;
const REFRESH_ON_OPEN_KEY = "birdnion.refreshOnOpen";
const PROVIDER_STORAGE_ENABLED_KEY = "birdnion.providerStorageFootprintsEnabled";
const STATUS_CHECKS_KEY = "birdnion.statusChecksEnabled";
const SESSION_NOTIFY_KEY = "birdnion.sessionQuotaNotificationsEnabled";
const QUOTA_WARN_KEY = "birdnion.quotaWarningNotificationsEnabled";
const QUOTA_WARN_L1_KEY = "birdnion.quotaWarnLevel1";
const QUOTA_WARN_L2_KEY = "birdnion.quotaWarnLevel2";
const SHOW_TRAY_PERCENT_KEY = "birdnion.showPercentInTray";
const HIDE_PERSONAL_KEY = "birdnion.hidePersonalInfo";
const REPO_URL = "https://github.com/hapo-nghialuu/BirdNion";

/** macOS RefreshFrequency options (seconds). */
export const REFRESH_OPTIONS: { value: number; vi: string; en: string }[] = [
  { value: 0, vi: "Thủ công", en: "Manual" },
  { value: 60, vi: "1 phút", en: "1 minute" },
  { value: 120, vi: "2 phút", en: "2 minutes" },
  { value: 300, vi: "5 phút", en: "5 minutes" },
  { value: 900, vi: "15 phút", en: "15 minutes" },
  { value: 3600, vi: "1 giờ", en: "1 hour" },
];

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Global poll interval in seconds, clamped to [30, 1800], default 120.
 * 0 = manual mode (mirrors macOS `RefreshFrequency.manual`): the background
 * tick loop stops auto-fetching and only an explicit refresh fetches. */
export function getPollSeconds(): number {
  const raw = localStorage.getItem(POLL_KEY);
  if (raw === null) return POLL_DEFAULT;
  const n = Number(raw);
  if (!Number.isFinite(n)) return POLL_DEFAULT;
  if (n === POLL_MANUAL) return POLL_MANUAL;
  return Math.min(POLL_MAX, Math.max(POLL_MIN, Math.trunc(n)));
}

/** True when the global interval is set to manual (0) — no auto-polling. */
export function isManualRefresh(): boolean {
  return getPollSeconds() === POLL_MANUAL;
}

export function setPollSeconds(seconds: number) {
  const clamped = seconds === POLL_MANUAL
    ? POLL_MANUAL
    : Math.min(POLL_MAX, Math.max(POLL_MIN, Math.trunc(seconds)));
  localStorage.setItem(POLL_KEY, String(clamped));
}

export function isStatusChecksEnabled(): boolean {
  return localStorage.getItem(STATUS_CHECKS_KEY) !== "false";
}
export function setStatusChecksEnabled(v: boolean) {
  localStorage.setItem(STATUS_CHECKS_KEY, String(v));
}
export function isSessionNotifyEnabled(): boolean {
  return localStorage.getItem(SESSION_NOTIFY_KEY) !== "false";
}
export function setSessionNotifyEnabled(v: boolean) {
  localStorage.setItem(SESSION_NOTIFY_KEY, String(v));
}
export function isQuotaWarnEnabled(): boolean {
  return localStorage.getItem(QUOTA_WARN_KEY) === "true";
}
export function setQuotaWarnEnabled(v: boolean) {
  localStorage.setItem(QUOTA_WARN_KEY, String(v));
}
export function getQuotaWarnL1(): number {
  const raw = localStorage.getItem(QUOTA_WARN_L1_KEY);
  const n = raw === null ? NaN : Number(raw);
  // NB: Number(null) is 0 — the old code silently returned threshold 0
  // for fresh installs instead of the macOS default 50.
  return Number.isFinite(n) && n > 0 ? n : 50;
}
export function setQuotaWarnL1(n: number) {
  localStorage.setItem(QUOTA_WARN_L1_KEY, String(n));
}
export function getQuotaWarnL2(): number {
  const raw = localStorage.getItem(QUOTA_WARN_L2_KEY);
  const n = raw === null ? NaN : Number(raw);
  return Number.isFinite(n) && n > 0 ? n : 20;
}
export function setQuotaWarnL2(n: number) {
  localStorage.setItem(QUOTA_WARN_L2_KEY, String(n));
}

/** Per-provider/per-window quota-warning override — macOS `QuotaWarnConfig`
 * (UserDefaults `quotaWarn.<provider>.<window>` CSV "warn,critical").
 * `windowKey` is "session" (5h) or "weekly". */
export type QuotaWarnConfig = { warn: number; critical: number };

const quotaWarnKey = (id: string, windowKey: string) => `birdnion.quotaWarn.${id}.${windowKey}`;

export function getProviderQuotaWarn(id: string, windowKey: string): QuotaWarnConfig | null {
  const raw = localStorage.getItem(quotaWarnKey(id, windowKey));
  if (!raw) return null;
  const [warn, critical] = raw.split(",").map(Number);
  if (!Number.isFinite(warn) || !Number.isFinite(critical)) return null;
  return { warn, critical };
}

export function setProviderQuotaWarn(id: string, windowKey: string, cfg: QuotaWarnConfig | null) {
  if (cfg) localStorage.setItem(quotaWarnKey(id, windowKey), `${cfg.warn},${cfg.critical}`);
  else localStorage.removeItem(quotaWarnKey(id, windowKey));
}

/** Effective thresholds for one quota window: the per-provider override when
 * customized, else the global L1/L2 pair. */
export function effectiveQuotaWarn(id: string, windowLabel: string): QuotaWarnConfig {
  const windowKey = windowLabel.includes("Tuần") ? "weekly" : "session";
  return getProviderQuotaWarn(id, windowKey) ?? { warn: getQuotaWarnL1(), critical: getQuotaWarnL2() };
}
/** When the key has never been written, default **on** so the tray shows %
 * next to the icon out of the box (macOS users who enable Display → show-%
 * expect the same on this shell; tooltip-only was invisible without hover). */
export function isShowTrayPercentEnabled(): boolean {
  const raw = localStorage.getItem(SHOW_TRAY_PERCENT_KEY);
  if (raw === null) return true;
  return raw === "true";
}
export function setShowTrayPercentEnabled(v: boolean) {
  localStorage.setItem(SHOW_TRAY_PERCENT_KEY, String(v));
  // Notify other webviews (main popover) so the tray title rebuilds immediately.
  // `storage` events only fire cross-window; same-window listeners need this.
  window.dispatchEvent(new CustomEvent("birdnion-tray-display-changed", { detail: { enabled: v } }));
  // Immediate clear when turning off — don't wait for main's next tick.
  if (!v) {
    void invoke("set_tray_status", {
      tooltip: "BirdNion",
      title: null,
      iconPng: null,
    }).catch(() => {});
  }
}

export const TRAY_PERCENT_STORAGE_KEY = SHOW_TRAY_PERCENT_KEY;
export function isHidePersonalInfo(): boolean {
  return localStorage.getItem(HIDE_PERSONAL_KEY) === "true";
}
export function setHidePersonalInfo(v: boolean) {
  localStorage.setItem(HIDE_PERSONAL_KEY, String(v));
}
export function setRefreshOnOpenEnabledPublic(enabled: boolean) {
  setRefreshOnOpenEnabled(enabled);
}
export function setProviderStorageEnabledPublic(enabled: boolean) {
  setProviderStorageEnabled(enabled);
}
export { REPO_URL };

/** Whether the window should re-fetch all providers each time it becomes
 * visible/focused — mirrors macOS `refreshOnMenuOpen` (default false). */
export function isRefreshOnOpenEnabled(): boolean {
  return localStorage.getItem(REFRESH_ON_OPEN_KEY) === "true";
}

function setRefreshOnOpenEnabled(enabled: boolean) {
  localStorage.setItem(REFRESH_ON_OPEN_KEY, String(enabled));
}

/** Whether provider detail rows show their on-disk storage footprint —
 * mirrors macOS `providerStorageFootprintsEnabled` (default false). */
export function isProviderStorageEnabled(): boolean {
  return localStorage.getItem(PROVIDER_STORAGE_ENABLED_KEY) === "true";
}

function setProviderStorageEnabled(enabled: boolean) {
  localStorage.setItem(PROVIDER_STORAGE_ENABLED_KEY, String(enabled));
}

/** Number input for the global refresh cadence (0 = manual), a "Refresh
 * now" button for on-demand fetches, and the refresh-on-open /
 * storage-footprint toggles. Changing the interval takes effect on the
 * next tick of main.ts's polling `setInterval` (re-read each cycle). */
export function globalPollingSection(onRefreshNow: () => void): HTMLElement {
  const section = el("div", "settings-section");
  section.append(el("div", "summary-label", t("settingsGlobalPolling")));
  const row = el("div", "settings-row");
  const field = el("label", "settings-inline-field");
  const input = document.createElement("input");
  input.type = "number";
  input.min = String(POLL_MANUAL);
  input.max = String(POLL_MAX);
  input.step = "10";
  input.className = "settings-input settings-input-narrow";
  input.value = String(getPollSeconds());
  input.addEventListener("change", () => {
    const n = Number(input.value);
    if (Number.isFinite(n) && n >= POLL_MANUAL) {
      setPollSeconds(n);
      input.value = String(getPollSeconds());
    } else {
      input.value = String(getPollSeconds());
    }
  });
  field.append(input, el("span", "settings-inline-label", t("settingsSeconds")));
  row.append(field);

  const refreshNowBtn = document.createElement("button");
  refreshNowBtn.type = "button";
  refreshNowBtn.className = "settings-refresh-now-btn";
  refreshNowBtn.textContent = t("settingsRefreshNow");
  refreshNowBtn.addEventListener("click", onRefreshNow);
  row.append(refreshNowBtn);

  section.append(row, el("div", "window-subtitle",
    isManualRefresh() ? t("settingsGlobalPollingManualHint") : t("settingsGlobalPollingSubtitle")));

  const refreshOnOpenRow = el("div", "settings-row");
  const refreshOnOpenHead = el("label", "settings-head");
  const refreshOnOpenCheck = document.createElement("input");
  refreshOnOpenCheck.type = "checkbox";
  refreshOnOpenCheck.checked = isRefreshOnOpenEnabled();
  refreshOnOpenCheck.addEventListener("change", () => {
    setRefreshOnOpenEnabled(refreshOnOpenCheck.checked);
  });
  refreshOnOpenHead.append(refreshOnOpenCheck, el("span", "provider-name", t("settingsRefreshOnOpen")));
  refreshOnOpenRow.append(refreshOnOpenHead);
  section.append(refreshOnOpenRow);

  const providerStorageRow = el("div", "settings-row");
  const providerStorageHead = el("label", "settings-head");
  const providerStorageCheck = document.createElement("input");
  providerStorageCheck.type = "checkbox";
  providerStorageCheck.checked = isProviderStorageEnabled();
  providerStorageCheck.addEventListener("change", () => {
    setProviderStorageEnabled(providerStorageCheck.checked);
  });
  providerStorageHead.append(providerStorageCheck, el("span", "provider-name", t("settingsProviderStorage")));
  providerStorageRow.append(providerStorageHead);
  section.append(providerStorageRow);

  return section;
}

/** About pane — macOS AboutPane remake: centered branding + link cards. */
export async function aboutSection(): Promise<HTMLElement> {
  const page = el("div", "settings-page about-page");
  page.style.maxWidth = "480px";
  page.style.margin = "0 auto";

  let version = "";
  try {
    version = await getVersion();
  } catch {
    version = "";
  }

  const header = el("div", "sw-pane-header");
  header.append(el("div", "sw-pane-title", t("settingsTabAbout")));
  page.append(header);

  // Centered branding + primary actions (no nested card for hero)
  const hero = el("div", "about-hero");
  const icon = document.createElement("img");
  icon.className = "about-hero-icon";
  icon.src = "/logos/app.png";
  icon.alt = "BirdNion";
  icon.draggable = false;
  icon.addEventListener("click", () => { void openUrl(REPO_URL).catch(() => {}); });
  hero.append(icon);
  hero.append(el("div", "about-hero-name", "BirdNion"));
  if (version) {
    hero.append(el("div", "about-hero-ver", `${t("settingsVersion")} ${version}`));
  }
  hero.append(el("div", "about-hero-tag", t("aboutTagline")));

  const actions = el("div", "about-hero-actions");
  const checkBtn = el("button", "sw-pill-btn ccp-primary", t("aboutCheckNow"));
  const statusLine = el("div", "about-update-status", "");
  checkBtn.addEventListener("click", () => {
    if ((checkBtn as HTMLButtonElement).disabled) return;
    (checkBtn as HTMLButtonElement).disabled = true;
    statusLine.textContent = t("settingsCheckingUpdate");
    void invoke<UpdateInfo | null>("check_update", {
      channel: getUpdateChannel(),
      currentVersion: version,
    })
      .then((info) => {
        statusLine.textContent = "";
        if (info) {
          statusLine.textContent = `${t("settingsUpdateAvailable")} ${info.version}`;
          const releaseLink = document.createElement("a");
          releaseLink.href = info.url;
          releaseLink.textContent = t("settingsViewRelease");
          releaseLink.addEventListener("click", (ev) => {
            ev.preventDefault();
            void openUrl(info.url).catch(() => {});
          });
          statusLine.append(" · ", releaseLink);
        } else {
          statusLine.textContent = t("settingsUpToDate");
        }
      })
      .catch((err) => {
        statusLine.textContent = `${t("loadError")}: ${err}`;
      })
      .finally(() => {
        (checkBtn as HTMLButtonElement).disabled = false;
      });
  });
  const notesBtn = el("button", "sw-pill-btn", t("aboutReleaseNotes"));
  notesBtn.addEventListener("click", () => {
    void openUrl(`${REPO_URL}/releases`).catch(() => {});
  });
  actions.append(checkBtn, notesBtn);
  hero.append(actions, statusLine);
  page.append(hero);

  // Links card
  const linksGroup = el("div", "sw-group");
  linksGroup.append(el("div", "sw-section-header", t("settingsSectionLinks")));
  const linksCard = el("div", "sw-card");
  const linksBody = el("div", "sw-card-body");
  const linkRows: [string, string][] = [
    ["GitHub", REPO_URL],
    ["Website", REPO_URL],
  ];
  linkRows.forEach(([label, url], i) => {
    if (i > 0) linksBody.append(el("div", "sw-row-divider"));
    const a = document.createElement("button");
    a.type = "button";
    a.className = "pp-link-row";
    a.append(el("span", "", label));
    a.append(el("span", "pp-link-arrow", "›"));
    a.addEventListener("click", () => { void openUrl(url).catch(() => {}); });
    linksBody.append(a);
  });
  // brew install row (copy command)
  linksBody.append(el("div", "sw-row-divider"));
  const brewRow = el("div", "sw-row about-brew-row");
  const brewText = el("div", "sw-row-text");
  brewText.append(el("div", "sw-row-title", t("aboutBrewInstall")));
  const brewCmd = "brew install --cask hapo-nghialuu/tap/birdnion";
  brewText.append(el("div", "sw-row-sub about-brew-cmd", brewCmd));
  const copyBtn = el("button", "sw-pill-btn", t("aboutCopy"));
  copyBtn.addEventListener("click", () => {
    void navigator.clipboard?.writeText(brewCmd).then(() => {
      copyBtn.textContent = t("aboutCopied");
      setTimeout(() => { copyBtn.textContent = t("aboutCopy"); }, 1500);
    }).catch(() => {});
  });
  brewRow.append(brewText, copyBtn);
  linksBody.append(brewRow);
  linksCard.append(linksBody);
  linksGroup.append(linksCard);
  page.append(linksGroup);

  page.append(el("div", "about-copyright", t("aboutCopyright")));
  return page;
}
