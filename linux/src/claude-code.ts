// Claude Code quick-apply — port of the macOS `ClaudeCodeQuickApplyButton` /
// `ClaudeCodePowerButton`: a card showing on/off/stale/needsSetup state for a
// provider backing the Claude Code CLI, with a circular power toggle that
// applies or deactivates the managed env block in ~/.claude/settings.json
// (or a project-scoped settings.json).

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";
import { settingsIcon } from "./settings-icons";

/** Providers that expose an Anthropic-compatible surface (mirrors the Rust
 * `claude_code::is_supported` / Swift `ClaudeCodeBackend.isSupported`). */
const SUPPORTED_IDS = new Set(["hapo", "minimax", "deepseek", "zai"]);

export function isClaudeCodeSupported(providerId: string): boolean {
  return SUPPORTED_IDS.has(providerId);
}

export type ClaudeCodePowerState = "on" | "off" | "stale" | "needsSetup";

export type ClaudeCodeState = {
  state: ClaudeCodePowerState;
  targetPath?: string | null;
};

/** Whether the popover/settings card should render for this provider: a
 * supported backend with a non-empty API key (mirrors the Swift
 * `shouldShow` gate). */
export function shouldShowClaudeCode(providerId: string, apiKey?: string | null): boolean {
  return isClaudeCodeSupported(providerId) && !!apiKey && apiKey.trim().length > 0;
}

export function fetchClaudeCodeState(providerId: string): Promise<ClaudeCodeState> {
  return invoke<ClaudeCodeState>("claude_code_state", { providerId });
}

export function applyClaudeCode(providerId: string): Promise<ClaudeCodeState> {
  return invoke<ClaudeCodeState>("claude_code_apply", { providerId });
}

export function deactivateClaudeCode(providerId: string): Promise<ClaudeCodeState> {
  return invoke<ClaudeCodeState>("claude_code_deactivate", { providerId });
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** macOS `claudeCode.state.*` — badge next to the title. */
function stateLabel(state: ClaudeCodePowerState): string {
  switch (state) {
    case "on": return t("ccStateOn");
    case "off": return t("ccStateOff");
    case "stale": return t("ccStateStale");
    case "needsSetup": return t("ccStateSetup");
  }
}

/** macOS `claudeCode.power.*` — subtitle under the title. */
function subtitle(state: ClaudeCodePowerState, providerName: string): string {
  switch (state) {
    case "on": return t("ccPowerOn", { name: providerName });
    case "off": return t("ccPowerOff");
    case "stale": return t("ccPowerStale");
    case "needsSetup": return t("ccNeedSetup");
  }
}

/** Short path for display: `/Users/foo/bar` → `~/bar` when under home. */
function displayPath(path: string): string {
  // Browser has no real home; use a common macOS/Linux pattern from the path.
  const m = path.match(/^(\/Users\/[^/]+|\/home\/[^/]+)(\/.*)?$/);
  if (m) return `~${m[2] ?? ""}`;
  return path;
}

/** macOS `claudeCode.quickCard.globalTarget` / `projectTarget`. */
function targetLabel(targetPath: string | null | undefined): string {
  if (!targetPath) return t("ccProjectNone");
  const shown = displayPath(targetPath);
  // Global: exactly ~/.claude/settings.json (not a project under home).
  if (shown === "~/.claude/settings.json") return t("ccGlobalTarget");
  return t("ccProjectTarget", { path: shown });
}

/** Compact status glyph left of the state label (SF Symbol-ish). */
function stateGlyph(state: ClaudeCodePowerState): string {
  switch (state) {
    case "on": return "✓";
    case "off": return "⏻";
    case "stale": return "↻";
    case "needsSetup": return "!";
  }
}

/**
 * Circular power button — port of macOS `ClaudeCodePowerButton`
 * (diameter 58 in the popover quick-apply card).
 */
function powerButton(
  state: ClaudeCodePowerState,
  busy: boolean,
  help: string,
  onClick: () => void,
): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = `cc-power cc-power-${state}${busy ? " cc-power-busy" : ""}`;
  btn.setAttribute("aria-label", help);
  btn.title = help;
  if (busy) btn.disabled = true;

  if (busy) {
    btn.append(el("span", "cc-power-spinner", ""));
  } else {
    btn.append(settingsIcon("power", "cc-power-icon"));
    if (state === "needsSetup" || state === "stale") {
      btn.append(el("span", "cc-power-dot", ""));
    }
  }

  btn.addEventListener("click", (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (!busy) onClick();
  });
  return btn;
}

/** Quick-apply card for a provider tab: terminal mark, status lines, and a
 * circular power toggle (macOS `ClaudeCodeQuickApplyButton` parity).
 * `onNeedsSetup` (e.g. jump to Settings → Claude Code) fires instead of
 * apply when models/path still need configuration. */
export function claudeCodeCard(
  providerId: string,
  providerName: string,
  onNeedsSetup?: () => void,
): HTMLElement {
  const card = el("div", "cc-card");
  const row = el("div", "cc-row");

  const iconWrap = el("div", "cc-lead-icon cc-lead-needsSetup");
  iconWrap.append(settingsIcon("terminal", "cc-lead-svg"));
  row.append(iconWrap);

  const body = el("div", "cc-body");
  const titleRow = el("div", "cc-title-row");
  titleRow.append(el("span", "cc-title", t("ccTitle")));
  const stateEl = el("span", "cc-state cc-state-needsSetup", "");
  titleRow.append(stateEl);
  body.append(titleRow);

  const sub = el("div", "cc-subtitle", "");
  const target = el("div", "cc-target", "");
  body.append(sub, target);
  row.append(body);

  const powerHost = el("div", "cc-power-host");
  row.append(powerHost);
  card.append(row);

  let current: ClaudeCodeState = { state: "needsSetup", targetPath: null };
  let busy = false;

  function paint() {
    const st = current.state;
    iconWrap.className = `cc-lead-icon cc-lead-${st}`;
    stateEl.className = `cc-state cc-state-${st}`;
    stateEl.textContent = "";
    stateEl.append(el("span", "cc-state-glyph", stateGlyph(st)));
    stateEl.append(document.createTextNode(` ${stateLabel(st)}`));
    sub.textContent = subtitle(st, providerName);
    target.textContent = targetLabel(current.targetPath);
    target.title = current.targetPath ?? "";

    powerHost.replaceChildren();
    powerHost.append(
      powerButton(st, busy, subtitle(st, providerName), () => { void onPowerTap(); }),
    );
  }

  async function refresh() {
    try {
      current = await fetchClaudeCodeState(providerId);
    } catch {
      current = { state: "needsSetup", targetPath: null };
    }
    busy = false;
    paint();
  }

  async function onPowerTap() {
    if (busy) return;
    if (current.state === "needsSetup") {
      onNeedsSetup?.();
      return;
    }
    busy = true;
    paint();
    try {
      current = current.state === "on" || current.state === "stale"
        ? await deactivateClaudeCode(providerId)
        : await applyClaudeCode(providerId);
    } catch (err) {
      sub.textContent = `${t("ccError")}: ${err}`;
      // Re-read real disk state so the button doesn't lie after a failed write.
      try {
        current = await fetchClaudeCodeState(providerId);
      } catch { /* keep last */ }
    }
    busy = false;
    paint();
  }

  void refresh();
  return card;
}
