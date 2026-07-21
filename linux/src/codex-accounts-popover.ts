// Codex accounts card in the POPOVER's codex tab — collapsible account list
// mirroring macOS `CodexAccountsPopoverSection`: header (person icon +
// "Tài khoản" + active label + count badge + chevron), expandable rows with
// radio + switch + trash for managed accounts, and "Lưu account hiện tại".
//
// Quota badge: macOS reads CodexAccountSnapshotStore for per-account remaining
// %; Linux has no snapshot store yet, so every row shows "—" (tertiary). Do
// not block this feature on missing badge data.

import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { settingsIcon } from "./settings-icons";

/** Same name as settings-tab's PROVIDERS_CHANGED_EVENT (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";
const EXPAND_KEY = "birdnion.codexAccountsExpanded";

type CodexAccount = { id: string; email?: string | null; isSystem: boolean; homePath?: string | null };
type CodexAccountsState = { accounts: CodexAccount[]; activeId: string };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function accountLabel(account: CodexAccount): string {
  if (account.isSystem) return account.email?.trim() || t("codexAccountSystem");
  return account.email?.trim() || account.id;
}

/** Collapsible Codex accounts card for the popover. `onResize` fires when the
 * card's height changes; `onSwitched` fires after an account switch so the
 * caller can refetch Codex quota. */
export function codexAccountsPopoverCard(onResize: () => void, onSwitched: () => void): HTMLElement {
  const card = el("section", "card fm-pop-card");
  let expanded = localStorage.getItem(EXPAND_KEY) === "true";
  let state: CodexAccountsState | null = null;
  let busy = false;

  const doSwitch = async (id: string) => {
    if (busy || !state || id === state.activeId) return;
    busy = true;
    render();
    let didSwitch = false;
    try {
      // Backend command is singular: codex_account_switch (not codex_accounts_*).
      state = await invoke<CodexAccountsState>("codex_account_switch", { id });
      didSwitch = true;
      await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
    } catch { /* keep old state */ }
    busy = false;
    render();
    if (didSwitch) onSwitched();
  };

  const render = () => {
    card.textContent = "";

    // Header: person icon + "Tài khoản" + active label + count + chevron.
    const head = el("button", "fm-pop-head");
    const icon = el("span", "fm-pop-icon");
    icon.append(settingsIcon("person", "fm-pop-icon-svg"));
    head.append(icon);
    const titles = el("span", "fm-pop-titles");
    titles.append(el("span", "fm-pop-title", t("popoverAccounts")));
    const active = state?.accounts.find((a) => a.id === state?.activeId);
    if (active) titles.append(el("span", "fm-pop-active", accountLabel(active)));
    head.append(titles);
    if (state) head.append(el("span", "fm-pop-count", String(state.accounts.length)));
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
    for (const account of state.accounts) {
      const row = el("div", "fm-pop-row");
      const isActive = account.id === state.activeId;
      row.append(el("span", `fm-pop-radio${isActive ? " on" : ""}`));

      const nameCol = el("span", "fm-pop-name-col");
      const name = el("span", "fm-pop-name", accountLabel(account));
      name.title = account.email ?? account.id;
      nameCol.append(name);
      nameCol.append(el(
        "span",
        "fm-pop-sub",
        account.isSystem ? t("codexAccountSystemManaged") : t("codexAccountAppManaged"),
      ));
      row.append(nameCol);

      // Per-account quota: Linux has no snapshot store — always "—".
      const quota = el("span", "fm-pop-quota", "—");
      quota.title = t("codexAccountQuotaMissing");
      row.append(quota);

      if (isActive) {
        row.append(el("span", "pp-account-badge", t("codexAccountActive")));
      } else {
        const useBtn = el("button", "sw-icon-btn fm-pop-switch") as HTMLButtonElement;
        useBtn.type = "button";
        useBtn.title = t("codexAccountSwitch");
        useBtn.setAttribute("aria-label", t("codexAccountSwitch"));
        useBtn.disabled = busy;
        useBtn.append(settingsIcon("arrow.clockwise", "fm-pop-switch-icon"));
        useBtn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          void doSwitch(account.id);
        });
        row.append(useBtn);
      }

      if (!account.isSystem) {
        const trashBtn = el("button", "sw-icon-btn ccp-danger fm-pop-trash") as HTMLButtonElement;
        trashBtn.type = "button";
        trashBtn.title = t("codexAccountRemove");
        trashBtn.setAttribute("aria-label", t("codexAccountRemove"));
        trashBtn.disabled = busy;
        trashBtn.append(settingsIcon("trash", "ccp-trash-icon"));
        trashBtn.addEventListener("click", async (ev) => {
          ev.stopPropagation();
          if (busy) return;
          const label = accountLabel(account);
          const ok = window.confirm(
            `${t("codexAccountRemoveTitle", { name: label })}\n\n${t("codexAccountRemoveMessage")}`,
          );
          if (!ok) return;
          busy = true;
          render();
          try {
            state = await invoke<CodexAccountsState>("codex_account_remove", { id: account.id });
            await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
            onSwitched();
          } catch { /* keep old state */ }
          busy = false;
          render();
          onResize();
        });
        row.append(trashBtn);
      }

      // Click row = set active (same backend as switch on Linux).
      row.style.cursor = "pointer";
      row.addEventListener("click", () => {
        void doSwitch(account.id);
      });
      list.append(row);
    }

    // "Lưu account hiện tại" — promote system login into a managed account.
    const footer = el("div", "fm-pop-footer");
    const saveBtn = el("button", "sw-pill-btn", busy ? "…" : t("codexAccountSaveCurrent")) as HTMLButtonElement;
    saveBtn.type = "button";
    saveBtn.disabled = busy;
    saveBtn.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      if (busy) return;
      busy = true;
      render();
      try {
        state = await invoke<CodexAccountsState>("codex_account_save_current");
        await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
      } catch { /* keep old state; errors also surface in Settings */ }
      busy = false;
      render();
      onResize();
    });
    footer.append(saveBtn);
    list.append(footer);
    card.append(list);
  };

  const reload = () => {
    void invoke<CodexAccountsState>("codex_accounts_list")
      .then((s) => {
        state = s;
        render();
        onResize();
      })
      .catch(() => {});
  };

  render();
  reload();
  // Settings window save/switch/remove → live list update (no restart).
  void listen(PROVIDERS_CHANGED_EVENT, () => { reload(); });
  return card;
}
