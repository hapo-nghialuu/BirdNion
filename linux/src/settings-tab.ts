// Settings view — provider enable/disable + API key/cookie entry, persisted
// straight into the shared ~/.config/birdnion/settings.json (same schema as
// macOS, so the two apps can share one config).

import { invoke } from "@tauri-apps/api/core";
import { t, currentLang } from "./i18n";
import { claudeCodeSettingsSection } from "./claude-code-settings";
import {
  reorderControls, refreshIntervalInput, trayVisibilityToggle, regionSelect,
} from "./settings-provider-row";
import { globalPollingSection, aboutSection } from "./settings-about";
import { copilotDeviceLoginRow } from "./settings-copilot-login";

type ProviderCfg = {
  id: string;
  apiKey?: string | null;
  enabled?: boolean | null;
  region?: string | null;
  refreshInterval?: number | null;
  showInTray?: boolean | null;
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
  claudeHaikuModel?: string | null;
  claudeSonnetModel?: string | null;
  claudeOpusModel?: string | null;
  claudeDisable1M?: boolean | null;
  claudeCodeScope?: string | null;
  claudeCodeProjectPath?: string | null;
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

const NAME_BY_ID = new Map(ROSTER);

/** Provider ids in display order: whatever order is already persisted in
 * settings.json (so drag/arrow reordering sticks across reloads), then any
 * roster entries not yet present in the file, in roster order. */
function orderedIds(settings: Settings): string[] {
  const seen = new Set(settings.providers.map((p) => p.id));
  const fromFile = settings.providers.map((p) => p.id).filter((id) => NAME_BY_ID.has(id));
  const missing = ROSTER.map(([id]) => id).filter((id) => !seen.has(id));
  return [...fromFile, ...missing];
}

function renderProviderRow(
  id: string, cfg: ProviderCfg, settings: Settings, vi: boolean, rerender: () => void,
): HTMLElement {
  const name = NAME_BY_ID.get(id) ?? id;
  const wrap = el("div", "settings-provider");
  const row = el("div", "settings-row");
  row.append(reorderControls(settings.providers, cfg, rerender));

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
    key.placeholder = t("settingsApiKey");
    key.value = cfg.apiKey ?? "";
    key.className = "settings-input";
    key.addEventListener("change", () => { cfg.apiKey = key.value.trim() || null; });
    row.append(key);
  }
  if (COOKIED.has(id)) {
    const cookie = document.createElement("input");
    cookie.type = "password";
    cookie.placeholder = t("settingsManualCookie");
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
    adminKey.placeholder = t("settingsAdminApiKey");
    adminKey.value = cfg.adminApiKey ?? "";
    adminKey.className = "settings-input";
    adminKey.addEventListener("change", () => { cfg.adminApiKey = adminKey.value.trim() || null; });
    row.append(adminKey);
  }
  wrap.append(row);

  const extrasRow = el("div", "settings-row settings-row-extras");
  extrasRow.append(refreshIntervalInput(cfg), trayVisibilityToggle(cfg));
  const region = regionSelect(cfg);
  if (region) extrasRow.append(region);
  wrap.append(extrasRow);

  const ccSection = claudeCodeSettingsSection(cfg);
  if (ccSection) wrap.append(ccSection);

  if (id === "copilot") {
    wrap.append(copilotDeviceLoginRow(vi, (label) => { cfg.accountLabel = label; }));
  }
  return wrap;
}

export async function settingsTab(onSaved: () => void): Promise<HTMLElement> {
  const container = el("div", "settings");
  const settings = await invoke<Settings>("get_settings");
  const vi = currentLang() === "vi";

  const listWrap = el("div", "settings-provider-list");
  container.append(el("div", "summary-label", t("settingsProvidersLabel")), listWrap);

  const renderList = () => {
    listWrap.textContent = "";
    const byId = new Map(settings.providers.map((p) => [p.id, p]));
    for (const id of orderedIds(settings)) {
      let cfg = byId.get(id);
      if (!cfg) {
        cfg = { id };
        byId.set(id, cfg);
        settings.providers.push(cfg);
      }
      listWrap.append(renderProviderRow(id, cfg, settings, vi, renderList));
    }
  };
  renderList();

  container.append(globalPollingSection());

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
    el("span", "provider-name", t("settingsLaunchAtLogin")));
  autostartRow.append(autostartHead);
  container.append(autostartRow);

  const save = el("button", "save-button", t("settingsSave"));
  save.addEventListener("click", async () => {
    save.textContent = "…";
    try {
      await invoke("save_settings", { settings });
      save.textContent = t("settingsSaved");
      setTimeout(onSaved, 400);
    } catch (err) {
      save.textContent = `${t("loadError")}: ${err}`;
    }
  });
  container.append(save);
  container.append(await aboutSection());
  return container;
}
