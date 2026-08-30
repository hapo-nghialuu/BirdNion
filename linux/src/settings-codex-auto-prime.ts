import { t } from "./i18n";
import {
  loadCodexAutoPrimePreferences,
  saveCodexAutoPrimePreferences,
} from "./codex-auto-prime";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function labeledRow(title: string, subtitle: string, control: HTMLElement): HTMLElement {
  const row = el("div", "sw-row");
  const text = el("div", "sw-row-text");
  text.append(el("div", "sw-row-title", title), el("div", "sw-row-sub", subtitle));
  row.append(text, control);
  return row;
}

function timeValue(minutes: number): string {
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

function parsedMinutes(value: string): number | null {
  const match = /^(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  return hour <= 23 && minute <= 59 ? hour * 60 + minute : null;
}

/** Settings card matching macOS CodexAutoPrimeCard. Preferences are local to
 * this platform and consumed by the main popover's existing refresh cadence. */
export function codexAutoPrimeCard(): HTMLElement {
  const preferences = loadCodexAutoPrimePreferences();
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("settingsCodexAutoPrimeTitle")));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");

  const toggle = document.createElement("input");
  toggle.type = "checkbox";
  toggle.className = "sw-switch";
  toggle.checked = preferences.enabled;
  toggle.setAttribute("aria-label", t("settingsCodexAutoPrimeToggle"));

  const time = document.createElement("input");
  time.type = "time";
  time.className = "settings-input codex-auto-prime-time";
  time.value = timeValue(preferences.scheduledMinutes);
  time.disabled = !preferences.enabled;
  time.setAttribute("aria-label", t("settingsCodexAutoPrimeTime"));

  const persist = () => saveCodexAutoPrimePreferences({
    enabled: toggle.checked,
    scheduledMinutes: parsedMinutes(time.value) ?? preferences.scheduledMinutes,
  });
  toggle.addEventListener("change", () => {
    time.disabled = !toggle.checked;
    persist();
  });
  time.addEventListener("change", persist);

  body.append(
    labeledRow(
      t("settingsCodexAutoPrimeToggle"),
      t("settingsCodexAutoPrimeToggleSubtitle"),
      toggle,
    ),
    el("div", "sw-row-divider"),
    labeledRow(
      t("settingsCodexAutoPrimeTime"),
      t("settingsCodexAutoPrimeTimeSubtitle"),
      time,
    ),
  );
  card.append(body);
  group.append(card);
  return group;
}
