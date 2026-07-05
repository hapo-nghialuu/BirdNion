// GitHub Copilot Device Flow login row — port of the macOS Settings'
// "Sign in to Copilot" flow: request a device code, show it plus the
// verification URL, then poll (JS-driven loop honoring `interval`/`slowDown`)
// until the user approves it in the browser.

import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t } from "./i18n";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

type DeviceCode = { userCode: string; verificationUri: string; deviceCode: string; interval: number };
type PollResult =
  | { kind: "pending" }
  | { kind: "slowDown" }
  | { kind: "success"; label: string }
  | { kind: "denied" }
  | { kind: "expired" };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function copilotDeviceLoginRow(vi: boolean, onLoggedIn: (label: string) => void): HTMLElement {
  const row = el("div", "settings-row");
  const button = el("button", "save-button", t("settingsSignInGithub"));
  const status = el("div", "window-subtitle");
  row.append(button, status);

  button.addEventListener("click", async () => {
    button.setAttribute("disabled", "true");
    status.textContent = "";
    status.textContent = vi ? "Đang lấy mã đăng nhập…" : "Requesting device code…";
    try {
      const code = await invoke<DeviceCode>("copilot_login_start");
      status.textContent = "";
      const codeText = el("span", "provider-name", code.userCode);
      const link = document.createElement("a");
      link.href = code.verificationUri;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = code.verificationUri;
      link.addEventListener("click", (ev) => {
        ev.preventDefault();
        void openUrl(code.verificationUri).catch(() => {});
      });
      status.append(
        el("span", "", vi ? "Mã: " : "Code: "), codeText,
        el("span", "", " · "), link,
      );
      void openUrl(code.verificationUri).catch(() => {});

      let interval = Math.max(1, code.interval);
      for (;;) {
        await sleep(interval * 1000);
        const result = await invoke<PollResult>("copilot_login_poll", { deviceCode: code.deviceCode });
        if (result.kind === "pending") continue;
        if (result.kind === "slowDown") { interval += 5; continue; }
        if (result.kind === "success") {
          status.textContent = vi ? `Đã đăng nhập: ${result.label}` : `Signed in: ${result.label}`;
          onLoggedIn(result.label);
          break;
        }
        if (result.kind === "denied") {
          status.textContent = vi ? "Yêu cầu đăng nhập bị từ chối." : "Login request was denied.";
          break;
        }
        status.textContent = vi ? "Hết thời gian chờ xác thực." : "Login request expired.";
        break;
      }
    } catch (err) {
      status.textContent = `${vi ? "Lỗi" : "Error"}: ${err}`;
    } finally {
      button.removeAttribute("disabled");
    }
  });

  return row;
}
