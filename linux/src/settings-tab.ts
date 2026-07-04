// Settings view — provider enable/disable + API key/cookie entry, persisted
// straight into the shared ~/.config/birdnion/settings.json (same schema as
// macOS, so the two apps can share one config).

import { invoke } from "@tauri-apps/api/core";
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
  }

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
