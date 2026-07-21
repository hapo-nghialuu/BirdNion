// App-wide appearance: light | dark | auto.
// Persists in localStorage (UI pref) and mirrors into settings.json
// (`appearance` field) for cross-session durability with the Rust config.

import { invoke } from "@tauri-apps/api/core";

const APPEARANCE_KEY = "birdnion.appearance";

export type Appearance = "light" | "dark" | "auto";
export type ResolvedTheme = "light" | "dark";

export function getAppearance(): Appearance {
  const raw = localStorage.getItem(APPEARANCE_KEY);
  if (raw === "light" || raw === "dark" || raw === "auto") return raw;
  return "auto";
}

export function setAppearance(mode: Appearance): void {
  localStorage.setItem(APPEARANCE_KEY, mode);
  applyTheme();
  window.dispatchEvent(new CustomEvent("birdnion-appearance-changed", { detail: mode }));
  // Best-effort persist into shared settings.json (does not block UI).
  void persistAppearanceToConfig(mode);
}

export function resolveTheme(mode: Appearance = getAppearance()): ResolvedTheme {
  if (mode === "light" || mode === "dark") return mode;
  try {
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  } catch {
    return "light";
  }
}

/** Apply `data-theme` on <html> so CSS token tables switch immediately. */
export function applyTheme(): ResolvedTheme {
  const mode = getAppearance();
  const resolved = resolveTheme(mode);
  const root = document.documentElement;
  root.setAttribute("data-theme", resolved);
  root.setAttribute("data-appearance", mode);
  root.style.colorScheme = resolved;
  return resolved;
}

let mediaBound = false;

/** Call once per webview: apply + follow system when appearance = auto. */
export function initTheme(): void {
  applyTheme();
  if (mediaBound) return;
  mediaBound = true;
  try {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => {
      if (getAppearance() === "auto") applyTheme();
    };
    if (typeof mq.addEventListener === "function") {
      mq.addEventListener("change", onChange);
    } else {
      // Safari / older WebKit
      mq.addListener(onChange);
    }
  } catch { /* ignore */ }

  // Cross-webview: Settings and popover share localStorage but not the same
  // document — re-apply when the other window writes appearance.
  window.addEventListener("storage", (e) => {
    if (e.key === APPEARANCE_KEY) applyTheme();
  });

  // Hydrate from settings.json if present (wins over default auto only when set).
  void hydrateFromConfig();
}

async function hydrateFromConfig(): Promise<void> {
  try {
    const settings = await invoke<{ appearance?: string | null }>("get_settings");
    const a = settings?.appearance;
    if (a === "light" || a === "dark" || a === "auto") {
      if (localStorage.getItem(APPEARANCE_KEY) == null) {
        localStorage.setItem(APPEARANCE_KEY, a);
        applyTheme();
      }
    }
  } catch { /* browser mock / pre-config */ }
}

async function persistAppearanceToConfig(mode: Appearance): Promise<void> {
  try {
    const settings = await invoke<Record<string, unknown>>("get_settings");
    if (!settings || typeof settings !== "object") return;
    if (settings.appearance === mode) return;
    settings.appearance = mode;
    await invoke("save_settings", { settings });
  } catch { /* ignore */ }
}
