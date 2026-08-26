// Codex accounts card in the POPOVER's codex tab — collapsible account list
// mirroring macOS `CodexAccountsPopoverSection`: header (person icon +
// "Tài khoản" + active label + count badge + chevron), expandable rows with
// radio + switch + trash for managed accounts, and "Lưu account hiện tại".
//
// Quota/health badge: passive snapshots are written by the existing Codex
// refresh. Accounts never scanned on this machine still show "—".

import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { quotaTone } from "./provider-tab";
import { settingsIcon } from "./settings-icons";
import { CODEX_ACCOUNT_CHANGED_EVENT } from "./settings-codex-accounts";
import type { Settings } from "./settings-provider-detail";
import {
  SETTINGS_SNAPSHOT_CHANGED_EVENT,
  type SettingsSnapshotState,
} from "./settings-persistence";

/** Same name as settings-tab's PROVIDERS_CHANGED_EVENT (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";
const EXPAND_KEY = "birdnion.codexAccountsExpanded";

type CodexAccount = { id: string; email?: string | null; isSystem: boolean; homePath?: string | null };
type AccountQuotaSnapshot = {
  label?: string | null;
  remainingPct?: number | null;
  lastChecked: number;
  errorKind?: string | null;
};
type CodexAccountsState = SettingsSnapshotState<Settings> & {
  accounts: CodexAccount[];
  activeId: string;
  quotaSnapshots: Record<string, AccountQuotaSnapshot>;
};

async function notifySettingsChanged(state: CodexAccountsState): Promise<void> {
  await emit(SETTINGS_SNAPSHOT_CHANGED_EVENT, state.settings);
}

async function notifyCodexAccountChanged(): Promise<void> {
  await emit(CODEX_ACCOUNT_CHANGED_EVENT);
}

async function performCodexAccountMutation<T>(operation: () => Promise<T>): Promise<T> {
  await notifyCodexAccountChanged();
  try {
    return await operation();
  } finally {
    await notifyCodexAccountChanged().catch(() => {});
  }
}

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

function checkedSuffix(snapshot: AccountQuotaSnapshot): string {
  if (!Number.isFinite(snapshot.lastChecked) || snapshot.lastChecked <= 0) return "";
  const checked = new Date(snapshot.lastChecked * 1000).toLocaleString();
  return ` · ${t("lastUpdated", { time: checked })}`;
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
      state = await performCodexAccountMutation(() =>
        invoke<CodexAccountsState>("codex_account_switch", { id }));
      await notifySettingsChanged(state);
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

      // Passive per-account snapshot: updated only by the normal Codex fetch.
      // Current health outranks a last-good percentage when the latest fetch
      // failed; the backend keeps that percentage for the next success.
      const snapshot = state.quotaSnapshots?.[account.id];
      const remaining = snapshot?.remainingPct;
      let quotaClass = "fm-pop-quota";
      let quotaText = "—";
      let quotaTitle = t("codexAccountQuotaMissing");
      if (snapshot?.errorKind) {
        quotaClass += " error";
        quotaText = "!";
        quotaTitle = `${t(`providerError.${snapshot.errorKind}.title`)} · ${t(`providerError.${snapshot.errorKind}.hint`)}`;
        quotaTitle += checkedSuffix(snapshot);
      } else if (typeof remaining === "number" && Number.isFinite(remaining)) {
        const pct = Math.max(0, Math.min(100, Math.round(remaining)));
        quotaClass += ` ${quotaTone(pct)}`;
        quotaText = `${pct}%`;
        quotaTitle = t("codexAccountQuotaHelp", {
          label: snapshot.label?.trim() || "Codex",
          n: pct,
        }) + checkedSuffix(snapshot);
      }
      const quota = el("span", quotaClass, quotaText);
      quota.title = quotaTitle;
      quota.setAttribute("aria-label", quotaTitle);
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
            state = await performCodexAccountMutation(() =>
              invoke<CodexAccountsState>("codex_account_remove", { id: account.id }));
            await notifySettingsChanged(state);
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
        state = await performCodexAccountMutation(() =>
          invoke<CodexAccountsState>("codex_account_save_current"));
        await notifySettingsChanged(state);
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
