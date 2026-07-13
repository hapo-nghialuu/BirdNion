// ElevenLabs keys card in the POPOVER's elevenlabs tab — collapsible
// switcher mirroring freemodel-accounts-popover: header + radio rows + switch.
// Adding keys stays in Settings; this card re-lists live when Settings emits
// birdnion-providers-changed (no app restart).

import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { settingsIcon } from "./settings-icons";

const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";
const EXPAND_KEY = "birdnion.elevenlabsKeysExpanded";

type ElevenLabsKey = { id: string; label?: string | null; preview: string };
type ElevenLabsKeysState = { keys: ElevenLabsKey[]; activeId: string | null };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function keyName(key: ElevenLabsKey): string {
  const label = key.label?.trim();
  return label || key.preview;
}

/** Collapsible ElevenLabs keys card for the popover. */
export function elevenlabsKeysPopoverCard(onResize: () => void, onSwitched: () => void): HTMLElement {
  const card = el("section", "card fm-pop-card");
  let expanded = localStorage.getItem(EXPAND_KEY) === "true";
  let state: ElevenLabsKeysState | null = null;
  let switching = false;

  const render = () => {
    card.textContent = "";

    const head = el("button", "fm-pop-head");
    const icon = el("span", "fm-pop-icon");
    icon.append(settingsIcon("key", "fm-pop-icon-svg"));
    head.append(icon);
    const titles = el("span", "fm-pop-titles");
    titles.append(el("span", "fm-pop-title", t("elKeysLabel")));
    const active = state?.keys.find((k) => k.id === state?.activeId);
    if (active) titles.append(el("span", "fm-pop-active", keyName(active)));
    else if (state) titles.append(el("span", "fm-pop-active", t("elKeysEmpty")));
    head.append(titles);
    if (state) head.append(el("span", "fm-pop-count", String(state.keys.length)));
    head.append(el("span", "fm-pop-chevron", expanded ? "▴" : "▾"));
    head.addEventListener("click", () => {
      expanded = !expanded;
      localStorage.setItem(EXPAND_KEY, String(expanded));
      render();
      onResize();
    });
    card.append(head);

    if (!expanded || !state) return;

    const list = el("div", "fm-pop-list");
    if (state.keys.length === 0) {
      list.append(el("div", "pp-field-hint ccp-nopad", t("elKeysEmpty")));
    }
    for (const key of state.keys) {
      const row = el("div", "fm-pop-row");
      const isActive = key.id === state.activeId;
      row.append(el("span", `fm-pop-radio${isActive ? " on" : ""}`));
      const name = el("span", "fm-pop-name", keyName(key));
      name.title = `${key.preview}…`;
      row.append(name);
      if (isActive) {
        row.append(el("span", "pp-account-badge", t("elKeyActive")));
      } else {
        const useBtn = el("button", "sw-pill-btn fm-pop-use", switching ? "…" : t("elKeySwitch"));
        useBtn.addEventListener("click", async (ev) => {
          ev.stopPropagation();
          if (switching) return;
          switching = true;
          render();
          let didSwitch = false;
          try {
            state = await invoke<ElevenLabsKeysState>("elevenlabs_key_switch", { id: key.id });
            didSwitch = true;
            await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
          } catch { /* keep old state */ }
          switching = false;
          render();
          if (didSwitch) onSwitched();
        });
        row.append(useBtn);
      }
      list.append(row);
    }
    card.append(list);
  };

  const reload = () => {
    void invoke<ElevenLabsKeysState>("elevenlabs_keys_list")
      .then((s) => {
        state = s;
        render();
        onResize();
      })
      .catch(() => {});
  };

  render();
  reload();
  // Settings window add/remove/switch → live list update (no restart).
  void listen(PROVIDERS_CHANGED_EVENT, () => { reload(); });
  return card;
}
