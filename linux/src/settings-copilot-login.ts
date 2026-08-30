// GitHub Copilot multi-account manager. OAuth tokens and raw device codes
// never cross IPC; the webview sees only account descriptors and an opaque
// login handle.

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t } from "./i18n";

export const COPILOT_ACCOUNT_CHANGED_EVENT = "birdnion-copilot-account-changed";

export type CopilotAccountChange = {
  phase: "before" | "after";
  origin: "settings" | "main";
};
export type CopilotAccount = { label: string; login: string | null; active: boolean };
export type CopilotAccountsState = {
  accounts: CopilotAccount[];
  activeLabel: string | null;
};
type DeviceCode = {
  userCode: string;
  verificationUri: string;
  interval: number;
  handle: string;
};
type PollResult =
  | { kind: "pending" }
  | { kind: "slowDown" }
  | { kind: "success"; label: string }
  | { kind: "denied" }
  | { kind: "expired" };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function notifyCopilotAccountChanged(change: CopilotAccountChange): Promise<void> {
  await emit(COPILOT_ACCOUNT_CHANGED_EVENT, change);
}

export async function performCopilotAccountMutation<T>(
  operation: () => Promise<T>,
  notify: (change: CopilotAccountChange) => Promise<void> = notifyCopilotAccountChanged,
  origin: CopilotAccountChange["origin"] = "settings",
): Promise<T> {
  await notify({ phase: "before", origin });
  try {
    return await operation();
  } finally {
    await notify({ phase: "after", origin }).catch(() => {});
  }
}

function accountName(account: CopilotAccount): string {
  return account.login?.trim() || account.label;
}

/** Settings body for list/switch/remove/add. Switch/remove wrap their durable
 * mutations; login invalidates only after success so quota stays visible while
 * the user completes Device Flow. */
export function copilotAccountsSection(readHost: () => string | null | undefined): HTMLElement {
  const wrap = el("div", "pp-accounts");
  const list = el("div", "pp-accounts-list");
  const status = el("div", "pp-accounts-status copilot-login-status");
  const footer = el("div", "pp-account-footer");
  const add = el("button", "sw-pill-btn", t("copilotAddAccount")) as HTMLButtonElement;
  add.type = "button";
  footer.append(add);
  wrap.append(list, status, footer);

  let state: CopilotAccountsState | null = null;
  let busy = false;

  const paint = () => {
    list.textContent = "";
    if (!state || state.accounts.length === 0) {
      list.append(el("div", "pp-account-empty sw-row-sub", t("copilotNoAccounts")));
    } else {
      for (const account of state.accounts) {
        const row = el("div", "pp-account-row");
        const name = el("span", "pp-account-name", accountName(account));
        if (account.login && account.login !== account.label) name.title = account.label;
        const actions = el("span", "pp-account-actions");
        if (account.active) {
          actions.append(el("span", "pp-account-badge", t("codexAccountActive")));
        } else {
          const use = el("button", "sw-pill-btn", t("codexAccountSwitch")) as HTMLButtonElement;
          use.type = "button";
          use.disabled = busy;
          use.addEventListener("click", () => { void mutateAccount("copilot_account_switch", account.label); });
          actions.append(use);
        }
        const remove = el(
          "button", "sw-pill-btn pp-account-remove", t("codexAccountRemove"),
        ) as HTMLButtonElement;
        remove.type = "button";
        remove.disabled = busy;
        remove.addEventListener("click", () => { void mutateAccount("copilot_account_remove", account.label); });
        actions.append(remove);
        row.append(name, actions);
        list.append(row);
      }
    }
    add.disabled = busy;
  };

  const load = async () => {
    state = await invoke<CopilotAccountsState>("copilot_accounts_list");
    paint();
  };

  const mutateAccount = async (command: string, label: string) => {
    if (busy) return;
    busy = true;
    status.textContent = "";
    status.classList.remove("error");
    paint();
    try {
      state = await performCopilotAccountMutation(() =>
        invoke<CopilotAccountsState>(command, { label }));
    } catch (error) {
      status.classList.add("error");
      status.textContent = `${t("loadError")}: ${error}`;
    } finally {
      busy = false;
      paint();
    }
  };

  const runLogin = async () => {
    const code = await invoke<DeviceCode>("copilot_login_start", {
      host: readHost()?.trim() || null,
    });
    status.classList.remove("error");
    status.textContent = "";
    const codeText = el("strong", "provider-name", code.userCode);
    const link = document.createElement("a");
    link.href = code.verificationUri;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = t("copilotOpenLogin");
    link.addEventListener("click", (event) => {
      event.preventDefault();
      void openUrl(code.verificationUri).catch(() => {});
    });
    status.append(el("span", "", `${t("copilotLoginCode")}: `), codeText, el("span", "", " · "), link);
    void openUrl(code.verificationUri).catch(() => {});

    let interval = Math.max(1, code.interval);
    for (;;) {
      await sleep(interval * 1000);
      const result = await invoke<PollResult>("copilot_login_poll", { handle: code.handle });
      if (result.kind === "pending") continue;
      if (result.kind === "slowDown") { interval += 5; continue; }
      if (result.kind === "success") {
        status.classList.remove("error");
        status.textContent = t("copilotLoginSuccess", { account: result.label });
        await performCopilotAccountMutation(load);
        return;
      }
      status.classList.add("error");
      status.textContent = result.kind === "denied" ? t("copilotLoginDenied") : t("copilotLoginExpired");
      return;
    }
  };

  add.addEventListener("click", async () => {
    if (busy) return;
    busy = true;
    status.textContent = t("copilotLoginRequesting");
    status.classList.remove("error");
    paint();
    try {
      await runLogin();
    } catch (error) {
      status.classList.add("error");
      status.textContent = `${t("loadError")}: ${error}`;
    } finally {
      busy = false;
      paint();
    }
  });

  paint();
  void load().catch((error) => {
    status.classList.add("error");
    status.textContent = `${t("loadError")}: ${error}`;
  });
  return wrap;
}
