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

/** GitHub Copilot Device Flow login row — port of the macOS Settings'
 * "Sign in to Copilot" flow: request a device code, show it plus the
 * verification URL, then poll until the user approves it in the browser. */
function copilotDeviceLoginRow(vi: boolean, onLoggedIn: (label: string) => void): HTMLElement {
  const row = el("div", "settings-row");
  const button = el("button", "save-button", vi ? "Đăng nhập Copilot" : "Sign in to Copilot");
  const status = el("div", "window-subtitle");
  row.append(button, status);

  button.addEventListener("click", async () => {
    button.setAttribute("disabled", "true");
    status.textContent = vi ? "Đang lấy mã đăng nhập…" : "Requesting device code…";
    try {
      const code = await invoke<DeviceCode>("copilot_device_start");
      status.textContent = "";
      const codeText = el("span", "provider-name", code.userCode);
      const link = document.createElement("a");
      link.href = code.verificationUri;
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

      const label = await invoke<string>("copilot_device_poll", {
        deviceCode: code.deviceCode,
        interval: code.interval,
      });
      status.textContent = vi ? `Đã đăng nhập: ${label}` : `Signed in: ${label}`;
      onLoggedIn(label);
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
