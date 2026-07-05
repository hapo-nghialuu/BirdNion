// About section + global polling-interval control at the bottom of Settings.
// The polling interval persists in localStorage (read by main.ts's tick
// loop) rather than settings.json, since it's a local UI preference, not a
// shared provider config value.

import { getVersion } from "@tauri-apps/api/app";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t } from "./i18n";

const POLL_KEY = "birdnion.pollSeconds";
const POLL_DEFAULT = 120;
const POLL_MIN = 30;
const POLL_MAX = 1800;
const REPO_URL = "https://github.com/hapo-nghialuu/BirdNion";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Global poll interval in seconds, clamped to [30, 1800], default 120. */
export function getPollSeconds(): number {
  const raw = Number(localStorage.getItem(POLL_KEY));
  if (!Number.isFinite(raw) || raw <= 0) return POLL_DEFAULT;
  return Math.min(POLL_MAX, Math.max(POLL_MIN, Math.trunc(raw)));
}

function setPollSeconds(seconds: number) {
  const clamped = Math.min(POLL_MAX, Math.max(POLL_MIN, Math.trunc(seconds)));
  localStorage.setItem(POLL_KEY, String(clamped));
}

/** Number input for the global refresh cadence. Changing it takes effect on
 * the next tick of main.ts's polling `setInterval` (re-read each cycle). */
export function globalPollingSection(): HTMLElement {
  const section = el("div", "settings-section");
  section.append(el("div", "summary-label", t("settingsGlobalPolling")));
  const row = el("div", "settings-row");
  const field = el("label", "settings-inline-field");
  const input = document.createElement("input");
  input.type = "number";
  input.min = String(POLL_MIN);
  input.max = String(POLL_MAX);
  input.step = "10";
  input.className = "settings-input settings-input-narrow";
  input.value = String(getPollSeconds());
  input.addEventListener("change", () => {
    const n = Number(input.value);
    if (Number.isFinite(n) && n > 0) {
      setPollSeconds(n);
      input.value = String(getPollSeconds());
    } else {
      input.value = String(getPollSeconds());
    }
  });
  field.append(input, el("span", "settings-inline-label", t("settingsSeconds")));
  row.append(field);
  section.append(row, el("div", "window-subtitle", t("settingsGlobalPollingSubtitle")));
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

  return section;
}
