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

/** Card-body content styled for the settings detail column — macOS
 * `CodexAccountsCard` rows: account name + "Đang dùng" badge / switch +
 * remove pills, and a footer "Lưu account hiện tại" action. */
export function codexAccountsSection(): HTMLElement {
  const wrap = el("div", "pp-accounts");
  const list = el("div", "pp-accounts-list");
  const status = el("div", "pp-accounts-status");
  wrap.append(list, status);

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
      const row = el("div", "pp-account-row");
      const isActive = account.id === state.activeId;
      row.append(el("span", "pp-account-name", accountLabel(account)));
      const actions = el("span", "pp-account-actions");
      if (isActive) {
        actions.append(el("span", "pp-account-badge", t("codexAccountActive")));
      } else {
        const useBtn = el("button", "sw-pill-btn", t("codexAccountSwitch")) as HTMLButtonElement;
        useBtn.type = "button";
        useBtn.addEventListener("click", async () => {
          try {
            await invoke("codex_account_switch", { id: account.id });
            await render();
          } catch (err) {
            status.textContent = `${t("loadError")}: ${err}`;
          }
        });
        actions.append(useBtn);
      }
      if (!account.isSystem) {
        const removeBtn = el("button", "sw-pill-btn pp-account-remove", t("codexAccountRemove")) as HTMLButtonElement;
        removeBtn.type = "button";
        removeBtn.addEventListener("click", async () => {
          try {
            await invoke("codex_account_remove", { id: account.id });
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

  const footer = el("div", "pp-account-footer");
  const saveBtn = el("button", "sw-pill-btn", t("codexAccountSaveCurrent")) as HTMLButtonElement;
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
  footer.append(saveBtn);
  wrap.append(footer);

  void render();
  return wrap;
}
