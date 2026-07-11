// FreeModel accounts card in the POPOVER's freemodel tab — collapsible
// account list mirroring macOS `CodexAccountsPopoverSection`: header row
// (icon + "Tài khoản" + count badge + chevron), expandable rows with an
// active radio + switch action. Managing accounts (add/remove cookies)
// stays in Settings; this is a fast switcher.

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { settingsIcon } from "./settings-icons";

/** Same name as settings-tab's PROVIDERS_CHANGED_EVENT (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";
const EXPAND_KEY = "birdnion.freemodelAccountsExpanded";

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
    if (account.id === "browser") return t("fmAccountBrowser");
    const browser = account.label ?? account.id.replace(/^browser:/, "");
    return account.email ? `${browser} · ${account.email}` : browser;
  }
  return account.label?.trim() || account.email?.trim() || account.id.slice(0, 8);
}

/** Collapsible FreeModel accounts card for the popover. `onResize` fires when
 * the card's height changes (list load / expand); `onSwitched` fires only
 * after an actual account switch so the caller can refetch the quota. */
export function freemodelAccountsPopoverCard(onResize: () => void, onSwitched: () => void): HTMLElement {
  const card = el("section", "card fm-pop-card");
  let expanded = localStorage.getItem(EXPAND_KEY) === "true";
  let state: FreemodelAccountsState | null = null;
  let switching = false;

  const render = () => {
    card.textContent = "";

    // Header row: person icon + label + count badge + chevron (click toggles).
    const head = el("button", "fm-pop-head");
    const icon = el("span", "fm-pop-icon");
    icon.append(settingsIcon("person", "fm-pop-icon-svg"));
    head.append(icon);
    const titles = el("span", "fm-pop-titles");
    titles.append(el("span", "fm-pop-title", t("fmAccountsLabel")));
    const active = state?.accounts.find((a) => a.id === state?.activeId);
    if (active) titles.append(el("span", "fm-pop-active", accountName(active)));
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
      const name = el("span", "fm-pop-name", accountName(account));
      name.title = account.email ?? "";
      row.append(name);
      if (isActive) {
        row.append(el("span", "pp-account-badge", t("codexAccountActive")));
      } else {
        const useBtn = el("button", "sw-pill-btn fm-pop-use", switching ? "…" : t("codexAccountSwitch"));
        useBtn.addEventListener("click", async (ev) => {
          ev.stopPropagation();
          if (switching) return;
          switching = true;
          render();
          let didSwitch = false;
          try {
            state = await invoke<FreemodelAccountsState>("freemodel_account_switch", { id: account.id });
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

  render();
  void invoke<FreemodelAccountsState>("freemodel_accounts_list")
    .then((s) => {
      state = s;
      render();
      onResize(); // window height changes once rows appear
    })
    .catch(() => {});
  return card;
}
