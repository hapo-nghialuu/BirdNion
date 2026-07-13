// ElevenLabs multi-key management — same card pattern as FreeModel accounts:
// list of managed API keys with switch/remove, plus an add form (key + optional label).

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { t } from "./i18n";

/** Same name as settings-tab's PROVIDERS_CHANGED_EVENT (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";

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

export function elevenlabsKeysSection(): HTMLElement {
  const wrap = el("div", "pp-accounts");
  const list = el("div", "pp-accounts-list");
  const status = el("div", "pp-accounts-status");
  wrap.append(list, status);

  const notifyChanged = () => emit(PROVIDERS_CHANGED_EVENT).catch(() => {});

  const render = async () => {
    list.textContent = "";
    status.textContent = "";
    let state: ElevenLabsKeysState;
    try {
      state = await invoke<ElevenLabsKeysState>("elevenlabs_keys_list");
    } catch (err) {
      status.textContent = `${t("loadError")}: ${err}`;
      return;
    }
    if (state.keys.length === 0) {
      list.append(el("div", "pp-field-hint ccp-nopad", t("elKeysEmpty")));
    }
    for (const key of state.keys) {
      const row = el("div", "pp-account-row");
      const nameWrap = el("span", "pp-account-name", keyName(key));
      nameWrap.title = `${key.preview}…`;
      row.append(nameWrap);
      const actions = el("span", "pp-account-actions");
      if (key.id === state.activeId) {
        actions.append(el("span", "pp-account-badge", t("elKeyActive")));
      } else {
        const useBtn = el("button", "sw-pill-btn", t("elKeySwitch")) as HTMLButtonElement;
        useBtn.type = "button";
        useBtn.addEventListener("click", async () => {
          try {
            await invoke("elevenlabs_key_switch", { id: key.id });
            await notifyChanged();
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        actions.append(useBtn);
      }
      const removeBtn = el("button", "sw-pill-btn pp-account-remove", t("codexAccountRemove")) as HTMLButtonElement;
      removeBtn.type = "button";
      removeBtn.addEventListener("click", async () => {
        try {
          await invoke("elevenlabs_key_remove", { id: key.id });
          await notifyChanged();
          await render();
        } catch (err) {
          status.textContent = `${t("loadError")}: ${err}`;
        }
      });
      actions.append(removeBtn);
      row.append(actions);
      list.append(row);
    }
  };

  // Add form: paste API key (password) + optional label.
  const form = el("div", "pp-account-add");
  const keyInput = document.createElement("input");
  keyInput.type = "password";
  keyInput.placeholder = t("elKeyPlaceholder");
  keyInput.className = "settings-input";
  const labelInput = document.createElement("input");
  labelInput.type = "text";
  labelInput.placeholder = t("elKeyLabelPlaceholder");
  labelInput.className = "settings-input";
  const addBtn = el("button", "sw-pill-btn", t("elKeyAdd")) as HTMLButtonElement;
  addBtn.type = "button";
  addBtn.addEventListener("click", async () => {
    const apiKey = keyInput.value.trim();
    if (!apiKey) return;
    addBtn.setAttribute("disabled", "true");
    addBtn.textContent = "…";
    try {
      await invoke("elevenlabs_key_add", {
        apiKey,
        label: labelInput.value.trim() || null,
      });
      keyInput.value = "";
      labelInput.value = "";
      await notifyChanged();
      await render();
    } catch (err) {
      status.textContent = String(err);
    } finally {
      addBtn.removeAttribute("disabled");
      addBtn.textContent = t("elKeyAdd");
    }
  });
  form.append(keyInput, labelInput, addBtn);
  const footer = el("div", "pp-account-footer");
  footer.append(el("div", "pp-field-hint ccp-nopad", t("elKeysAddHint")));
  footer.append(form);
  wrap.append(footer);

  void render();
  return wrap;
}
