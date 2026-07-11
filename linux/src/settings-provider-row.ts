// Provider row extras for the Settings list: reorder arrows, per-provider
// refresh-interval override, tray-visibility toggle, and region picker.
// Mirrors macOS `ProvidersPane` (drag reorder → arrows here for a dense
// list), `QuotaService.overrideInterval` (`refreshInterval.<id>` semantics),
// and `MenuBarVisibility` (`showInTray`, default true).

import { t, currentLang } from "./i18n";

export type ProviderRowCfg = {
  id: string;
  refreshInterval?: number | null;
  showInTray?: boolean | null;
  region?: string | null;
  source?: string | null;
};

/** Claude data-source options, mirroring macOS `ClaudeUsageDataSource`. */
const CLAUDE_SOURCE_OPTIONS: { value: string; labelKey: string }[] = [
  { value: "auto", labelKey: "claudeSourceAuto" },
  { value: "oauth", labelKey: "claudeSourceOauth" },
  { value: "web", labelKey: "claudeSourceWeb" },
  { value: "cli", labelKey: "claudeSourceCli" },
  { value: "api", labelKey: "claudeSourceApi" },
];

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Region options per provider id, mirroring the macOS `*Region` enums.
 * Providers not listed here have no fixed-choice region (e.g. Bedrock uses
 * a free-text AWS region field elsewhere). */
const REGION_OPTIONS: Record<string, { value: string; vi: string; en: string }[]> = {
  minimax: [
    { value: "io", vi: "Toàn cầu (platform.minimax.io)", en: "Global (platform.minimax.io)" },
    { value: "com", vi: "Trung Quốc (platform.minimaxi.com)", en: "China (platform.minimaxi.com)" },
  ],
  zai: [
    { value: "global", vi: "Toàn cầu (api.z.ai)", en: "Global (api.z.ai)" },
    { value: "cn", vi: "BigModel CN (open.bigmodel.cn)", en: "BigModel CN (open.bigmodel.cn)" },
  ],
  alibaba: [
    { value: "intl", vi: "Quốc tế (Singapore)", en: "International (Singapore)" },
    { value: "cn", vi: "Trung Quốc đại lục (Bắc Kinh)", en: "China Mainland (Beijing)" },
  ],
};

/** Move `cfg` up/down within `providers` in place. Returns true when moved. */
export function moveProvider(providers: { id: string }[], id: string, direction: -1 | 1): boolean {
  const from = providers.findIndex((p) => p.id === id);
  if (from < 0) return false;
  const to = from + direction;
  if (to < 0 || to >= providers.length) return false;
  const [item] = providers.splice(from, 1);
  providers.splice(to, 0, item);
  return true;
}

/**
 * Swap an **enabled** provider with the previous/next enabled peer, ignoring
 * disabled rows. Keeps Settings sidebar order (active block) in lockstep with
 * popover tab order, which only shows enabled providers.
 */
export function moveEnabledProvider(
  providers: { id: string; enabled?: boolean | null }[],
  id: string,
  direction: -1 | 1,
): boolean {
  const enabledIdx = providers
    .map((p, i) => (p.enabled === true ? i : -1))
    .filter((i) => i >= 0);
  const pos = enabledIdx.findIndex((i) => providers[i]!.id === id);
  if (pos < 0) return false;
  const swapPos = pos + direction;
  if (swapPos < 0 || swapPos >= enabledIdx.length) return false;
  const a = enabledIdx[pos]!;
  const b = enabledIdx[swapPos]!;
  const tmp = providers[a]!;
  providers[a] = providers[b]!;
  providers[b] = tmp;
  return true;
}

/** Reorder arrow buttons (↑/↓). `onMoved` re-renders the settings list.
 * When `enabledOnly` is true (default), arrows move among active providers
 * only — matches the popover tab strip. */
export function reorderControls(
  providers: { id: string; enabled?: boolean | null }[],
  cfg: ProviderRowCfg,
  onMoved: () => void,
  enabledOnly = true,
): HTMLElement {
  const wrap = el("span", "settings-reorder");
  const move = (dir: -1 | 1) => {
    const ok = enabledOnly
      ? moveEnabledProvider(providers, cfg.id, dir)
      : moveProvider(providers, cfg.id, dir);
    if (ok) onMoved();
  };
  const up = document.createElement("button");
  up.className = "reorder-btn";
  up.textContent = "↑";
  up.type = "button";
  up.title = t("settingsMoveUp");
  up.addEventListener("click", (ev) => {
    ev.stopPropagation();
    move(-1);
  });
  const down = document.createElement("button");
  down.className = "reorder-btn";
  down.textContent = "↓";
  down.type = "button";
  down.title = t("settingsMoveDown");
  down.addEventListener("click", (ev) => {
    ev.stopPropagation();
    move(1);
  });
  wrap.append(up, down);
  return wrap;
}

/** Checkbox toggling whether this provider appears in the tray tooltip
 * rotation. Default (checked) mirrors `MenuBarVisibility.isShown` = true. */
export function trayVisibilityToggle(cfg: ProviderRowCfg): HTMLElement {
  const wrap = el("label", "settings-inline-field");
  const check = document.createElement("input");
  check.type = "checkbox";
  check.checked = cfg.showInTray !== false;
  check.addEventListener("change", () => { cfg.showInTray = check.checked; });
  wrap.append(check, el("span", "settings-inline-label", t("settingsShowInTray")));
  return wrap;
}

/** Region `<select>` for providers with a fixed region choice, or `null`
 * when the provider has none. */
export function regionSelect(cfg: ProviderRowCfg): HTMLElement | null {
  const options = REGION_OPTIONS[cfg.id];
  if (!options) return null;
  const vi = currentLang() === "vi";
  const wrap = el("label", "settings-inline-field");
  wrap.append(el("span", "settings-inline-label", t("settingsRegion")));
  const select = document.createElement("select");
  select.className = "settings-input settings-input-narrow";
  for (const opt of options) {
    const optionEl = document.createElement("option");
    optionEl.value = opt.value;
    optionEl.textContent = vi ? opt.vi : opt.en;
    select.append(optionEl);
  }
  select.value = cfg.region ?? options[0].value;
  select.addEventListener("change", () => { cfg.region = select.value; });
  wrap.append(select);
  return wrap;
}

/** Claude data-source `<select>` (auto/oauth/web/cli/api) — mirrors macOS
 * `ClaudeUsageDataSource` / `UserDefaults` key `claudeUsageDataSource`. */
export function claudeSourceSelect(cfg: ProviderRowCfg): HTMLElement {
  const wrap = el("label", "settings-inline-field");
  wrap.append(el("span", "settings-inline-label", t("settingsClaudeSource")));
  const select = document.createElement("select");
  select.className = "settings-input settings-input-narrow settings-input-wide";
  for (const opt of CLAUDE_SOURCE_OPTIONS) {
    const optionEl = document.createElement("option");
    optionEl.value = opt.value;
    optionEl.textContent = t(opt.labelKey);
    select.append(optionEl);
  }
  select.value = cfg.source ?? "oauth";
  select.addEventListener("change", () => { cfg.source = select.value === "oauth" ? null : select.value; });
  wrap.append(select);
  return wrap;
}
