// Settings view — provider enable/disable + API key/cookie entry, persisted
// straight into the shared ~/.config/birdnion/settings.json (same schema as
// macOS, so the two apps can share one config).

import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t, currentLang } from "./i18n";

type ProviderCfg = {
  id: string;
  apiKey?: string | null;
  enabled?: boolean | null;
  region?: string | null;
  baseUrl?: string | null;
  displayName?: string | null;
  accountLabel?: string | null;
  projectId?: string | null;
  secretKey?: string | null;
  awsAuthMode?: string | null;
  awsProfile?: string | null;
  budget?: number | null;
  cookieSource?: string | null;
  manualCookie?: string | null;
  adminApiKey?: string | null;
};

type Settings = { version: number; providers: ProviderCfg[] };

/** Full roster (macOS parity), in default display order. */
const ROSTER: [string, string][] = [
  ["claude", "Claude"], ["codex", "Codex"], ["minimax", "MiniMax"],
  ["hapo", "Hapo AI Hub"], ["openrouter", "OpenRouter"], ["deepseek", "DeepSeek"],
  ["zai", "z.ai"], ["elevenlabs", "ElevenLabs"], ["deepgram", "Deepgram"],
  ["groq", "Groq"], ["copilot", "Copilot"], ["kilo", "Kilo"],
  ["commandcode", "CommandCode"], ["freemodel", "Freemodel"], ["mimo", "MiMo"],
  ["alibaba", "Alibaba"], ["cursor", "Cursor"], ["gemini", "Gemini"],
  ["kiro", "Kiro"], ["opencode", "OpenCode"], ["opencodego", "OpenCodeGo"],
  ["antigravity", "Antigravity"], ["bedrock", "Bedrock"],
];

/** Providers whose auth is a pasted API key. */
const KEYED = new Set([
  "minimax", "hapo", "openrouter", "deepseek", "zai", "elevenlabs",
  "deepgram", "groq", "kiro", "kilo", "alibaba", "bedrock",
]);
/** Providers that can use browser cookies. */
const COOKIED = new Set([
  "opencode", "opencodego", "commandcode", "cursor", "mimo",
  "alibaba", "freemodel", "copilot",
]);

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

/** GitHub Copilot Device Flow login row — port of the macOS Settings'
 * "Sign in to Copilot" flow: request a device code, show it plus the
 * verification URL, then poll (JS-driven loop honoring `interval`/`slowDown`)
 * until the user approves it in the browser. */
function copilotDeviceLoginRow(vi: boolean, onLoggedIn: (label: string) => void): HTMLElement {
  const row = el("div", "settings-row");
  const button = el("button", "save-button", vi ? "Đăng nhập GitHub" : "Sign in with GitHub");
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

export async function settingsTab(onSaved: () => void): Promise<HTMLElement> {
  const container = el("div", "settings");
  const settings = await invoke<Settings>("get_settings");
  const byId = new Map(settings.providers.map((p) => [p.id, p]));

  const vi = currentLang() === "vi";
  container.append(el("div", "summary-label",
    vi ? "Providers (lưu vào ~/.config/birdnion/settings.json)"
       : "Providers (saved to ~/.config/birdnion/settings.json)"));

  for (const [id, name] of ROSTER) {
    const cfg: ProviderCfg = byId.get(id) ?? { id };
    if (!byId.has(id)) {
      byId.set(id, cfg);
      settings.providers.push(cfg);
    }

    const row = el("div", "settings-row");
    const head = el("label", "settings-head");
    const check = document.createElement("input");
    check.type = "checkbox";
    check.checked = cfg.enabled === true;
    check.addEventListener("change", () => { cfg.enabled = check.checked; });
    head.append(check, el("span", "provider-name", name));
    row.append(head);

    if (KEYED.has(id)) {
      const key = document.createElement("input");
      key.type = "password";
      key.placeholder = "API key";
      key.value = cfg.apiKey ?? "";
      key.className = "settings-input";
      key.addEventListener("change", () => { cfg.apiKey = key.value.trim() || null; });
      row.append(key);
    }
    if (COOKIED.has(id)) {
      const cookie = document.createElement("input");
      cookie.type = "password";
      cookie.placeholder = vi ? "Cookie thủ công (tuỳ chọn)" : "Manual cookie (optional)";
      cookie.value = cfg.manualCookie ?? "";
      cookie.className = "settings-input";
      cookie.addEventListener("change", () => {
        cookie.value.trim()
          ? ((cfg.manualCookie = cookie.value.trim()), (cfg.cookieSource = "manual"))
          : ((cfg.manualCookie = null), (cfg.cookieSource = null));
      });
      row.append(cookie);
    }
    if (id === "claude") {
      const adminKey = document.createElement("input");
      adminKey.type = "password";
      adminKey.placeholder = vi ? "Admin API key (tuỳ chọn, dashboard tổ chức)" : "Admin API key (optional, org dashboard)";
      adminKey.value = cfg.adminApiKey ?? "";
      adminKey.className = "settings-input";
      adminKey.addEventListener("change", () => { cfg.adminApiKey = adminKey.value.trim() || null; });
      row.append(adminKey);
    }
    container.append(row);

    if (id === "copilot") {
      container.append(copilotDeviceLoginRow(vi, (label) => { cfg.accountLabel = label; }));
    }
  }

  // Launch-at-login (XDG autostart entry via tauri-plugin-autostart).
  const autostartRow = el("div", "settings-row");
  const autostartHead = el("label", "settings-head");
  const autostartCheck = document.createElement("input");
  autostartCheck.type = "checkbox";
  autostartCheck.checked = await invoke<boolean>("get_autostart").catch(() => false);
  autostartCheck.addEventListener("change", () => {
    void invoke("set_autostart", { enabled: autostartCheck.checked }).catch(() => {
      autostartCheck.checked = !autostartCheck.checked;
    });
  });
  autostartHead.append(autostartCheck,
    el("span", "provider-name", vi ? "Khởi động cùng hệ thống" : "Launch at login"));
  autostartRow.append(autostartHead);
  container.append(autostartRow);

  const save = el("button", "save-button", vi ? "Lưu cài đặt" : "Save settings");
  save.addEventListener("click", async () => {
    save.textContent = "…";
    try {
      await invoke("save_settings", { settings });
      save.textContent = vi ? "Đã lưu ✓" : "Saved ✓";
      setTimeout(onSaved, 400);
    } catch (err) {
      save.textContent = `${t("loadError")}: ${err}`;
    }
  });
  container.append(save);
  return container;
}
