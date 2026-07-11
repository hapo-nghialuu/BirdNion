// FreeModel multi-account management — same card pattern as the Codex
// accounts section: "browser" (live cookie scan) + managed pasted-cookie
// accounts with switch/remove, plus an add form (cookie + optional label).

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { t } from "./i18n";

/** Same name as settings-tab's PROVIDERS_CHANGED_EVENT (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";

type FreemodelAccount = { id: string; email?: string | null; label?: string | null; isBrowser: boolean };
type FreemodelAccountsState = { accounts: FreemodelAccount[]; activeId: string };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function accountName(account: FreemodelAccount): string {
  if (account.isBrowser) {
    // "browser" = auto scan; "browser:<name>" = a specific signed-in browser
    // shown as "Chrome · user@x.com".
    if (account.id === "browser") return t("fmAccountBrowser");
    const browser = account.label ?? account.id.replace(/^browser:/, "");
    return account.email ? `${browser} · ${account.email}` : browser;
  }
  return account.label?.trim() || account.email?.trim() || account.id.slice(0, 8);
}

export function freemodelAccountsSection(): HTMLElement {
  const wrap = el("div", "pp-accounts");
  const list = el("div", "pp-accounts-list");
  const status = el("div", "pp-accounts-status");
  wrap.append(list, status);

  const notifyChanged = () => emit(PROVIDERS_CHANGED_EVENT).catch(() => {});

  const render = async () => {
    list.textContent = "";
    status.textContent = "";
    let state: FreemodelAccountsState;
    try {
      state = await invoke<FreemodelAccountsState>("freemodel_accounts_list");
    } catch (err) {
      status.textContent = `${t("loadError")}: ${err}`;
      return;
    }
    for (const account of state.accounts) {
      const row = el("div", "pp-account-row");
      const nameWrap = el("span", "pp-account-name", accountName(account));
      // Secondary line: email under a custom label (helps tell accounts apart).
      if (!account.isBrowser && account.label && account.email) nameWrap.title = account.email;
      row.append(nameWrap);
      const actions = el("span", "pp-account-actions");
      if (account.id === state.activeId) {
        actions.append(el("span", "pp-account-badge", t("codexAccountActive")));
      } else {
        const useBtn = el("button", "sw-pill-btn", t("codexAccountSwitch")) as HTMLButtonElement;
        useBtn.type = "button";
        useBtn.addEventListener("click", async () => {
          try {
            await invoke("freemodel_account_switch", { id: account.id });
            await notifyChanged();
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        actions.append(useBtn);
      }
      if (!account.isBrowser) {
        const removeBtn = el("button", "sw-pill-btn pp-account-remove", t("codexAccountRemove")) as HTMLButtonElement;
        removeBtn.type = "button";
        removeBtn.addEventListener("click", async () => {
          try {
            await invoke("freemodel_account_remove", { id: account.id });
            await notifyChanged();
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        actions.append(removeBtn);
      }
      row.append(actions);
      list.append(row);
    }
  };

  // Add form: paste cookie (password field — it's a secret) + optional label.
  const form = el("div", "pp-account-add");
  const cookieInput = document.createElement("input");
  cookieInput.type = "password";
  cookieInput.placeholder = t("fmAccountCookiePlaceholder");
  cookieInput.className = "settings-input";
  const labelInput = document.createElement("input");
  labelInput.type = "text";
  labelInput.placeholder = t("fmAccountLabelPlaceholder");
  labelInput.className = "settings-input";
  const addBtn = el("button", "sw-pill-btn", t("fmAccountAdd")) as HTMLButtonElement;
  addBtn.type = "button";
  addBtn.addEventListener("click", async () => {
    const cookie = cookieInput.value.trim();
    if (!cookie) return;
    addBtn.setAttribute("disabled", "true");
    addBtn.textContent = "…";
    try {
      await invoke("freemodel_account_add", {
        cookie,
        label: labelInput.value.trim() || null,
      });
      cookieInput.value = "";
      labelInput.value = "";
      await render();
    } catch (err) {
      status.textContent = String(err);
    } finally {
      addBtn.removeAttribute("disabled");
      addBtn.textContent = t("fmAccountAdd");
    }
  });
  form.append(cookieInput, labelInput, addBtn);
  const footer = el("div", "pp-account-footer");
  footer.append(el("div", "pp-field-hint ccp-nopad", t("fmAccountAddHint")));
  footer.append(form);
  wrap.append(footer);

  void render();
  return wrap;
}
