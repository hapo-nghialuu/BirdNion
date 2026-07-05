// Claude Code quick-apply — port of the macOS `ClaudeCodeQuickApplyButton` /
// `ClaudeCodePowerButton`: a card showing on/off/stale/needsSetup state for a
// provider backing the Claude Code CLI, with a toggle that applies or
// deactivates the managed env block in ~/.claude/settings.json (or a
// project-scoped settings.json).

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";

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

function stateLabel(state: ClaudeCodePowerState): string {
  switch (state) {
    case "on": return t("ccStateOn");
    case "off": return t("ccStateOff");
    case "stale": return t("ccStateStale");
    case "needsSetup": return t("ccStateSetup");
  }
}

function subtitle(state: ClaudeCodePowerState, providerName: string): string {
  switch (state) {
    case "on": return t("ccPowerOn", { name: providerName });
    case "off": return t("ccPowerOff");
    case "stale": return t("ccPowerStale");
    case "needsSetup": return t("ccNeedSetup");
  }
}

function targetLabel(targetPath: string | null | undefined): string {
  return targetPath || t("ccProjectNone");
}

/** Quick-apply card for a provider tab: state badge, target path line, and a
 * toggle button that applies/deactivates then re-reads state. `onNeedsSetup`
 * (e.g. jump to the Settings tab) fires instead of calling apply when the
 * provider still needs its models configured — mirrors the Swift button's
 * open-Settings fallback. */
export function claudeCodeCard(
  providerId: string,
  providerName: string,
  onNeedsSetup?: () => void,
): HTMLElement {
  const card = el("div", "cc-card");
  const head = el("div", "cc-head");
  head.append(el("span", "cc-title", t("ccTitle")));
  const badge = el("span", "cc-badge cc-needsSetup", stateLabel("needsSetup"));
  head.append(badge);
  card.append(head);

  const sub = el("div", "cc-subtitle", "");
  const target = el("div", "cc-target", "");
  const button = el("button", "cc-toggle", "…");
  button.setAttribute("disabled", "true");
  card.append(sub, target, button);

  let current: ClaudeCodeState = { state: "needsSetup", targetPath: null };

  function paint() {
    badge.className = `cc-badge cc-${current.state}`;
    badge.textContent = stateLabel(current.state);
    sub.textContent = subtitle(current.state, providerName);
    target.textContent = targetLabel(current.targetPath);
    button.textContent = current.state === "on" || current.state === "stale"
      ? t("ccStateOff") : t("ccStateOn");
    button.removeAttribute("disabled");
  }

  async function refresh() {
    try {
      current = await fetchClaudeCodeState(providerId);
    } catch {
      current = { state: "needsSetup", targetPath: null };
    }
    paint();
  }

  button.addEventListener("click", async () => {
    if (current.state === "needsSetup") {
      onNeedsSetup?.();
      return;
    }
    button.setAttribute("disabled", "true");
    button.textContent = "…";
    try {
      current = current.state === "on" || current.state === "stale"
        ? await deactivateClaudeCode(providerId)
        : await applyClaudeCode(providerId);
    } catch (err) {
      sub.textContent = `${t("ccError")}: ${err}`;
    }
    paint();
  });

  void refresh();
  return card;
}
