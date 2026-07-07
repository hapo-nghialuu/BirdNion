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
const POLL_MAX = 1800;
const REFRESH_ON_OPEN_KEY = "birdnion.refreshOnOpen";
const PROVIDER_STORAGE_ENABLED_KEY = "birdnion.providerStorageFootprintsEnabled";
const REPO_URL = "https://github.com/hapo-nghialuu/BirdNion";

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

function setPollSeconds(seconds: number) {
  const clamped = seconds === POLL_MANUAL
    ? POLL_MANUAL
    : Math.min(POLL_MAX, Math.max(POLL_MIN, Math.trunc(seconds)));
  localStorage.setItem(POLL_KEY, String(clamped));
}

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

/** App name, version, and a link to the GitHub repo. */
export async function aboutSection(): Promise<HTMLElement> {
  const section = el("div", "settings-section");
  section.append(el("div", "summary-label", t("settingsAbout")));

  const nameRow = el("div", "settings-row");
  nameRow.append(el("span", "provider-name", "BirdNion"));
  let version = "";
  try {
    version = await getVersion();
  } catch {
    version = "";
  }
  if (version) {
    nameRow.append(el("span", "window-subtitle", `${t("settingsVersion")}: ${version}`));
  }
  section.append(nameRow);

  const linkRow = el("div", "settings-row");
  const link = document.createElement("a");
  link.href = REPO_URL;
  link.textContent = t("settingsRepo");
  link.addEventListener("click", (ev) => {
    ev.preventDefault();
    void openUrl(REPO_URL).catch(() => {});
  });
  linkRow.append(link);
  section.append(linkRow);

  section.append(updateCheckRow(version));

  return section;
}

/** "Check for updates" button + result line (up to date / update available
 * with a link to the release page) — port of macOS `UpdateChecker`. */
function updateCheckRow(currentVersion: string): HTMLElement {
  const row = el("div", "settings-row");
  const button = document.createElement("button");
  button.type = "button";
  button.className = "settings-refresh-now-btn";
  button.textContent = t("settingsCheckUpdate");
  const result = el("span", "window-subtitle", "");
  row.append(button, result);

  button.addEventListener("click", () => {
    if (button.disabled) return;
    button.disabled = true;
    result.textContent = t("settingsCheckingUpdate");
    void invoke<UpdateInfo | null>("check_update", {
      channel: getUpdateChannel(),
      currentVersion,
    })
      .then((info) => {
        result.textContent = "";
        if (info) {
          result.textContent = `${t("settingsUpdateAvailable")} ${info.version}`;
          const releaseLink = document.createElement("a");
          releaseLink.href = info.url;
          releaseLink.textContent = t("settingsViewRelease");
          releaseLink.addEventListener("click", (ev) => {
            ev.preventDefault();
            void openUrl(info.url).catch(() => {});
          });
          result.append(" · ", releaseLink);
        } else {
          result.textContent = t("settingsUpToDate");
        }
      })
      .catch((err) => {
        result.textContent = `${t("loadError")}: ${err}`;
      })
      .finally(() => {
        button.disabled = false;
      });
  });

  return row;
}
