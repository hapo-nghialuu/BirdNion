// Claude Code section of a provider's Settings row — port of the macOS
// "Claude Code" Settings pane fields (scope, project path, per-tier models,
// 1M-context toggle). Persisted through the caller's shared `save_settings`
// object (no separate Tauri command), matching the existing settings-tab
// pattern of mutating `cfg` in place and saving on demand.

import { t, currentLang } from "./i18n";
import { isClaudeCodeSupported } from "./claude-code";

export type ClaudeCodeProviderCfg = {
  id: string;
  apiKey?: string | null;
  claudeHaikuModel?: string | null;
  claudeSonnetModel?: string | null;
  claudeOpusModel?: string | null;
  claudeDisable1M?: boolean | null;
  claudeCodeScope?: string | null;
  claudeCodeProjectPath?: string | null;
};

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Renders the Claude Code config block for one provider row, or `null` when
 * the provider can't back Claude Code. Mutates `cfg` in place as the user
 * edits fields — the caller's existing "Save settings" button persists it. */
export function claudeCodeSettingsSection(cfg: ClaudeCodeProviderCfg): HTMLElement | null {
  if (!isClaudeCodeSupported(cfg.id)) return null;
  const vi = currentLang() === "vi";
  const section = el("div", "cc-settings-section");
  section.append(el("div", "summary-label", t("ccTitle")));

  // Scope: global vs project.
  const scopeRow = el("div", "cc-settings-row");
  const scopeLabel = el("label", "", t("ccScope"));
  const scopeSelect = document.createElement("select");
  scopeSelect.className = "settings-input";
  for (const [value, label] of [["global", t("ccScopeGlobal")], ["project", t("ccScopeProject")]]) {
    const opt = document.createElement("option");
    opt.value = value;
    opt.textContent = label;
    scopeSelect.append(opt);
  }
  scopeSelect.value = cfg.claudeCodeScope === "project" ? "project" : "global";
  scopeRow.append(scopeLabel, scopeSelect);
  section.append(scopeRow);

  // Project path (only meaningful in project scope, but always editable so
  // switching back to project restores the previous folder).
  const pathRow = el("div", "cc-settings-row");
  const pathLabel = el("label", "", t("ccProjectPath"));
  const pathInput = document.createElement("input");
  pathInput.type = "text";
  pathInput.placeholder = vi ? "/duong/dan/project" : "/path/to/project";
  pathInput.value = cfg.claudeCodeProjectPath ?? "";
  pathInput.className = "settings-input";
  pathRow.append(pathLabel, pathInput);
  section.append(pathRow);

  scopeSelect.addEventListener("change", () => { cfg.claudeCodeScope = scopeSelect.value; });
  pathInput.addEventListener("change", () => {
    cfg.claudeCodeProjectPath = pathInput.value.trim() || null;
  });

  // The 3 model tiers the macOS pane writes to ANTHROPIC_DEFAULT_*_MODEL.
  const modelField = (label: string, value: string | null | undefined, onChange: (v: string) => void) => {
    const row = el("div", "cc-settings-row");
    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = label;
    input.value = value ?? "";
    input.className = "settings-input";
    input.addEventListener("change", () => onChange(input.value.trim()));
    row.append(el("label", "", label), input);
    return row;
  };
  section.append(modelField(t("ccModelHaiku"), cfg.claudeHaikuModel,
    (v) => { cfg.claudeHaikuModel = v || null; }));
  section.append(modelField(t("ccModelSonnet"), cfg.claudeSonnetModel,
    (v) => { cfg.claudeSonnetModel = v || null; }));
  section.append(modelField(t("ccModelOpus"), cfg.claudeOpusModel,
    (v) => { cfg.claudeOpusModel = v || null; }));

  // 1M-context toggle (CLAUDE_CODE_DISABLE_1M_CONTEXT).
  const disableRow = el("div", "cc-settings-row");
  const disableLabel = el("label", "", t("ccDisable1M"));
  const disableCheck = document.createElement("input");
  disableCheck.type = "checkbox";
  disableCheck.checked = cfg.claudeDisable1M === true;
  disableCheck.addEventListener("change", () => { cfg.claudeDisable1M = disableCheck.checked; });
  disableRow.append(disableCheck, disableLabel);
  section.append(disableRow);

  return section;
}
