// Codex multi-account management row — port of the macOS `CodexAccountStore`
// UI: list known accounts (system + managed), switch the active one, save
// the current system login as a new managed account ("Lưu account hiện
// tại"), and remove managed accounts.

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

type CodexAccount = { id: string; email?: string | null; isSystem: boolean; homePath?: string | null };
type CodexAccountsState = { accounts: CodexAccount[]; activeId: string };

function accountLabel(account: CodexAccount): string {
  if (account.isSystem) return t("codexAccountSystem");
  return account.email ?? account.id;
}

export function codexAccountsSection(): HTMLElement {
  const wrap = el("div", "settings-row settings-codex-accounts");
  const list = el("div", "codex-account-list");
  const status = el("div", "window-subtitle");
  wrap.append(el("span", "settings-inline-label", t("codexAccountsLabel")), list, status);

  const render = async () => {
    list.textContent = "";
    status.textContent = "";
    let state: CodexAccountsState;
    try {
      state = await invoke<CodexAccountsState>("codex_accounts_list");
    } catch (err) {
      status.textContent = `${t("codexAccountLoadError")}: ${err}`;
      return;
    }
    for (const account of state.accounts) {
      const row = el("div", "codex-account-row");
      const isActive = account.id === state.activeId;
      row.append(el("span", "provider-name", accountLabel(account)));
      if (isActive) {
        row.append(el("span", "provider-meta", t("codexAccountActive")));
      } else {
        const useBtn = el("button", "reorder-btn", t("codexAccountSwitch")) as HTMLButtonElement;
        useBtn.type = "button";
        useBtn.addEventListener("click", async () => {
          try {
            await invoke("codex_account_switch", { id: account.id });
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        row.append(useBtn);
      }
      if (!account.isSystem) {
        const removeBtn = el("button", "reorder-btn", t("codexAccountRemove")) as HTMLButtonElement;
        removeBtn.type = "button";
        removeBtn.addEventListener("click", async () => {
          try {
            await invoke("codex_account_remove", { id: account.id });
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        row.append(removeBtn);
      }
      list.append(row);
    }
  };

  const saveBtn = el("button", "save-button", t("codexAccountSaveCurrent")) as HTMLButtonElement;
  saveBtn.type = "button";
  saveBtn.addEventListener("click", async () => {
    saveBtn.setAttribute("disabled", "true");
    try {
      await invoke("codex_account_save_current");
      await render();
    } catch (err) {
      status.textContent = `${t("loadError")}: ${err}`;
    } finally {
      saveBtn.removeAttribute("disabled");
    }
  });
  wrap.append(saveBtn);

  void render();
  return wrap;
}
