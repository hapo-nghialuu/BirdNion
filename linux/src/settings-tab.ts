// Settings view — provider enable/disable + API key/cookie entry, persisted
// straight into the shared ~/.config/birdnion/settings.json (same schema as
// macOS, so the two apps can share one config).

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { t, currentLang } from "./i18n";
import { reorderControls } from "./settings-provider-row";
import { logoMark } from "./logos";
import { lowestWindow, type ProviderStatus } from "./provider-tab";
import {
  detailInfoGrid, usageSection, setupSection, quotaWarningCard, linksSection,
  codexAccountsCard, freemodelAccountsCard, elevenlabsKeysCard, hiyoKeysCard, relativeUpdated, displayError,
  type ProviderCfg, type Settings,
} from "./settings-provider-detail";

/** Fired after settings.json provider list/order/enabled changes so the main
 * popover can rebuild tab strip order (macOS `.birdnionProvidersChanged`). */
export const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";

type OnboardingDetection = { isReady: boolean; source: string };
type OnboardingTestState = "idle" | "testing" | "live" | "failed";
const ONBOARDING_IDS = new Set(["claude", "codex", "grok"]);

async function persistProvidersAndNotify(settings: Settings): Promise<void> {
  await invoke("save_settings", { settings });
  await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
}

/** Full roster (macOS parity), in default display order. */
const ROSTER: [string, string][] = [
  ["claude", "Claude"], ["codex", "Codex"], ["minimax", "MiniMax"],
  ["hapo", "Hapo AI Hub"], ["openrouter", "OpenRouter"], ["tryapi", "TryAPI"], ["deepseek", "DeepSeek"],
  ["zai", "z.ai"], ["elevenlabs", "ElevenLabs"], ["hiyo", "Hiyo"], ["deepgram", "Deepgram"],
  ["groq", "Groq"], ["grok", "Grok"], ["openai", "OpenAI"], ["ollama", "Ollama"],
  ["copilot", "Copilot"], ["kilo", "Kilo"],
  ["commandcode", "CommandCode"], ["freemodel", "Freemodel"], ["mimo", "MiMo"],
  ["alibaba", "Alibaba"], ["cursor", "Cursor"], ["gemini", "Gemini"],
  ["kiro", "Kiro"], ["opencode", "OpenCode"], ["opencodego", "OpenCodeGo"],
  ["antigravity", "Antigravity"], ["bedrock", "Bedrock"],
];

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** id → display name; exported for the popover's placeholder tabs. */
export const NAME_BY_ID = new Map(ROSTER);

/** Provider ids in display order: whatever order is already persisted in
 * settings.json (so drag/arrow reordering sticks across reloads), then any
 * roster entries not yet present in the file, in roster order. */
function orderedIds(settings: Settings): string[] {
  const seen = new Set(settings.providers.map((p) => p.id));
  const fromFile = settings.providers.map((p) => p.id).filter((id) => NAME_BY_ID.has(id));
  const missing = ROSTER.map(([id]) => id).filter((id) => !seen.has(id));
  return [...fromFile, ...missing];
}

/**
 * Providers tab — macOS ProvidersPane two-pane layout:
 * left sidebar (search + roster + enable + status) / right detail (header +
 * info + usage + settings fields).
 */
export async function providersPane(onSaved: () => void): Promise<HTMLElement> {
  const vi = currentLang() === "vi";
  const settings = await invoke<Settings>("get_settings").catch(() => ({ version: 1, providers: [] as ProviderCfg[] }));
  // Ensure full roster present in memory.
  const byId = new Map(settings.providers.map((p) => [p.id, p]));
  for (const id of orderedIds(settings)) {
    if (!byId.has(id)) {
      const cfg = { id };
      settings.providers.push(cfg);
      byId.set(id, cfg);
    }
  }

  let selectedId = localStorage.getItem("birdnion.selectedProvider")
    || orderedIds(settings).find((id) => byId.get(id)?.enabled === true)
    || orderedIds(settings)[0]
    || "claude";
  // Shared with Settings window top search (`birdnion-sidebar-search`) —
  // no second search field in the provider roster.
  let searchQuery =
    typeof (window as { __birdnionSidebarSearch?: string }).__birdnionSidebarSearch === "string"
      ? (window as { __birdnionSidebarSearch?: string }).__birdnionSidebarSearch!
      : "";
  let statuses: ProviderStatus[] = [];
  const detections = new Map<string, OnboardingDetection>();
  const onboardingTests = new Map<string, OnboardingTestState>();

  const root = el("div", "pp-root");
  const sidebar = el("div", "pp-sidebar");
  const detail = el("div", "pp-detail");
  root.append(sidebar, detail);

  const onSharedSearch = ((ev: CustomEvent<string>) => {
    searchQuery = ev.detail ?? "";
    renderSidebar();
  }) as EventListener;
  window.addEventListener("birdnion-sidebar-search", onSharedSearch);

  const statusById = () => new Map(statuses.map((s) => [s.id, s]));

  /**
   * Sidebar order (macOS ProvidersPane.visibleRows parity):
   * 1. **Enabled** first — user custom order from settings.providers / arrow reorder
   * 2. **Disabled** after — A→Z by display name
   */
  const visibleIds = (): string[] => {
    const q = searchQuery.trim().toLowerCase();
    const ids = orderedIds(settings);
    const filtered = ids.filter((id) => {
      if (!q) return true;
      const name = sidebarName(id).toLowerCase();
      return name.includes(q) || id.includes(q);
    });
    // Active: keep file/roster order (reorder arrows rewrite settings.providers).
    const active = filtered.filter((id) => byId.get(id)?.enabled === true);
    // Inactive: alphabet so the long disabled list is scannable.
    const inactive = filtered
      .filter((id) => byId.get(id)?.enabled !== true)
      .sort((a, b) =>
        sidebarName(a).localeCompare(sidebarName(b), undefined, { sensitivity: "base" }),
      );
    return [...active, ...inactive];
  };

  /** Name shown in the sidebar row — prefer custom displayName (e.g. Hapo). */
  const sidebarName = (id: string): string => {
    const cfg = byId.get(id);
    const custom = cfg?.displayName?.trim();
    if (custom) return custom;
    return NAME_BY_ID.get(id) ?? id;
  };

  const subtitleFor = (id: string): {
    text: string; isError: boolean; quotaClass?: string;
  } => {
    const st = statusById().get(id);
    const cfg = byId.get(id);
    if (cfg?.enabled !== true) {
      return { text: t("provider.disabled"), isError: false };
    }
    if (st?.error) {
      const msg = displayError(st.error);
      return { text: msg.slice(0, 40) + (msg.length > 40 ? "…" : ""), isError: true };
    }
    if (st && st.windows.length > 0) {
      // `st.windows.length > 0` guarantees lowestWindow returns non-null.
      const lowest = lowestWindow(st)!;
      const pct = lowest.remainingPct;
      // Quota % colored by level in the list (P4 reskin).
      const quotaClass = pct <= 20 ? "critical" : pct <= 50 ? "warning" : "ok";
      return {
        text: t("provider.remainingPct", { n: pct }),
        isError: false,
        quotaClass,
      };
    }
    return { text: t("provider.noDataShort"), isError: false };
  };

  const renderSidebar = () => {
    sidebar.textContent = "";
    const list = el("div", "pp-sidebar-list");
    for (const id of visibleIds()) {
      const cfg = byId.get(id)!;
      const name = sidebarName(id);
      const row = el("div", `pp-side-row${id === selectedId ? " selected" : ""}`);
      row.dataset.id = id;

      const check = document.createElement("input");
      check.type = "checkbox";
      check.className = "pp-check";
      check.checked = cfg.enabled === true;
      check.addEventListener("click", (ev) => ev.stopPropagation());
      check.addEventListener("change", () => {
        cfg.enabled = check.checked;
        renderSidebar();
        renderDetail();
      });

      // macOS sidebarLogoTint: enabled → dark/black mono; disabled → gray mono.
      // (Never use brand multi-color marks in the sidebar.)
      const enabled = cfg.enabled === true;
      const logo = logoMark(
        id,
        `pp-side-logo tab-logo-mono${enabled ? " pp-logo-on" : " pp-logo-off"}`,
      );
      const text = el("div", "pp-side-text");
      const nameEl = el("div", `pp-side-name${enabled ? "" : " off"}`, name);
      text.append(nameEl);
      const sub = subtitleFor(id);
      const subCls = [
        "pp-side-sub",
        sub.isError ? "error" : "",
        sub.quotaClass ? `quota-${sub.quotaClass}` : "",
      ].filter(Boolean).join(" ");
      const subEl = el("div", subCls, sub.text);
      text.append(subEl);

      const dot = el("span", `pp-dot${cfg.enabled !== true ? " off" : sub.isError ? " warn" : " ok"}`);

      row.append(check, logo, text, dot);
      // Reorder arrows on the selected **enabled** row only — swaps among
      // active peers (same order as popover tabs). Persists immediately
      // (macOS drag-drop finish) so tabs stay in sync.
      if (id === selectedId && cfg.enabled === true) {
        row.append(reorderControls(settings.providers, cfg, () => {
          renderSidebar();
          void persistProvidersAndNotify(settings)
            .then(() => onSaved())
            .catch(() => {});
        }, true));
      }
      row.addEventListener("click", () => {
        selectedId = id;
        localStorage.setItem("birdnion.selectedProvider", id);
        renderSidebar();
        renderDetail();
      });
      list.append(row);
    }
    sidebar.append(list);
  };

  const renderDetail = () => {
    detail.textContent = "";
    const cfg = byId.get(selectedId);
    if (!cfg) {
      detail.append(el("div", "pp-empty", t("provider.choose")));
      return;
    }
    const name = NAME_BY_ID.get(selectedId) ?? selectedId;
    const st = statusById().get(selectedId);
    const enabled = cfg.enabled === true;
    const scroll = el("div", "pp-detail-scroll");

    const runConnectionTest = async () => {
      if (onboardingTests.get(selectedId) === "testing") return;
      onboardingTests.set(selectedId, "testing");
      renderDetail();
      try {
        cfg.enabled = true;
        await persistProvidersAndNotify(settings);
        const result = await invoke<ProviderStatus>("test_provider", { id: selectedId });
        const index = statuses.findIndex((item) => item.id === selectedId);
        if (index >= 0) statuses[index] = result;
        else statuses.push(result);
        onboardingTests.set(selectedId, result.error || result.windows.length === 0 ? "failed" : "live");
        renderSidebar();
        onSaved();
      } catch {
        onboardingTests.set(selectedId, "failed");
      }
      renderDetail();
    };

    const onboardingCard = (): HTMLElement | null => {
      if (!ONBOARDING_IDS.has(selectedId)) return null;
      const detection = detections.get(selectedId) ?? { isReady: false, source: "" };
      const explicit = onboardingTests.get(selectedId) ?? "idle";
      const phase: OnboardingTestState | "needsSource" | "readyToTest" =
        explicit !== "idle" ? explicit
          : st?.error ? "failed"
          : st && st.windows.length > 0 ? "live"
          : detection.isReady ? "readyToTest" : "needsSource";
      const labels: Record<string, string> = {
        needsSource: vi ? "Chưa phát hiện nguồn đăng nhập" : "No sign-in source detected",
        readyToTest: vi ? `Đã phát hiện ${detection.source}` : `Detected ${detection.source}`,
        testing: vi ? "Đang kiểm tra kết nối thật…" : "Testing the real connection…",
        live: vi ? "Quota đang live" : "Quota is live",
        failed: vi ? "Kết nối cần được sửa" : "Connection needs attention",
      };
      const group = el("div", "sw-group pp-onboarding");
      group.append(el("div", "sw-section-header", vi ? "KẾT NỐI PROVIDER" : "CONNECT PROVIDER"));
      const card = el("div", "sw-card pp-onboarding-card");
      const status = el("div", `pp-onboarding-status ${phase}`, labels[phase]);
      const note = el("div", "pp-field-hint",
        vi
          ? "BirdNion chỉ đánh dấu Live sau khi provider trả quota thật. Không sao chép hoặc hiển thị token."
          : "BirdNion marks Live only after the provider returns real quota. Tokens are never copied or displayed.");
      const actions = el("div", "pp-onboarding-actions");
      const connect = el("button", "save-button",
        phase === "failed" ? (vi ? "Thử lại" : "Retry") : (vi ? "Kết nối & kiểm tra" : "Connect & test"));
      connect.toggleAttribute("disabled", phase === "testing");
      connect.addEventListener("click", () => { void runConnectionTest(); });
      actions.append(connect);
      if (phase === "needsSource" || phase === "failed") {
        const fix = el("button", "sw-pill-btn", vi ? "Sửa thiết lập" : "Fix setup");
        fix.addEventListener("click", () => {
          scroll.querySelector(".pp-setup-wrap")?.scrollIntoView({ behavior: "smooth", block: "start" });
        });
        actions.append(fix);
      }
      card.append(status, note, actions);
      group.append(card);
      return group;
    };

    // Header card — macOS detailHeader: logo + name + "version • updated"
    // subtitle + self-test (inline result) + reload + enable switch.
    const head = el("div", "sw-card pp-head-card");
    const headRow = el("div", "pp-head-row");
    headRow.append(logoMark(selectedId, "pp-detail-logo"));
    const titles = el("div", "pp-head-titles");
    titles.append(el("div", "pp-head-name", name));
    const subParts = [st?.version, relativeUpdated(st?.lastUpdated)].filter(Boolean) as string[];
    titles.append(el("div", "pp-head-sub",
      subParts.length > 0 ? subParts.join(" • ") : (enabled ? t("provider.notLoaded") : t("provider.disabled"))));
    headRow.append(titles);

    const actions = el("div", "pp-head-actions");
    const testBtn = el("button", "sw-pill-btn", t("provider.selfTest"));
    const testResult = el("div", "pp-selftest-result");
    testBtn.addEventListener("click", async () => {
      testResult.className = "pp-selftest-result running";
      testResult.textContent = t("provider.selfTest.running");
      try {
        const res = await invoke<ProviderStatus>("test_provider", { id: selectedId });
        if (res.error || res.windows.length === 0) {
          const raw = res.error || (vi ? "Provider không trả dữ liệu quota." : "Provider returned no quota data.");
          const suffix = (await invoke<string | null>("classify_provider_error", { raw }).catch(() => null)) ?? "unknown";
          testResult.className = "pp-selftest-result fail";
          testResult.textContent = `${t("provider.selfTest.fail")} — ${t(`providerError.${suffix}.hint`)}`;
          testResult.title = displayError(raw);
        } else {
          testResult.className = "pp-selftest-result pass";
          testResult.textContent = t("provider.selfTest.pass");
        }
        // Refresh the status cache for this id so grid/usage reflect the probe.
        const idx = statuses.findIndex((s) => s.id === selectedId);
        if (idx >= 0) statuses[idx] = res;
        else statuses.push(res);
        renderSidebar();
      } catch (err) {
        testResult.className = "pp-selftest-result fail";
        testResult.textContent = `${t("provider.selfTest.fail")} — ${String(err)}`;
      }
    });
    const reloadBtn = el("button", "sw-icon-btn");
    reloadBtn.title = t("provider.reload");
    reloadBtn.textContent = "↻";
    reloadBtn.addEventListener("click", () => { void refreshStatuses().then(() => { renderSidebar(); renderDetail(); }); });

    const enable = document.createElement("input");
    enable.type = "checkbox";
    enable.className = "sw-switch";
    enable.checked = enabled;
    enable.addEventListener("change", () => {
      cfg.enabled = enable.checked;
      renderSidebar();
      renderDetail();
    });

    actions.append(testBtn, reloadBtn, enable);
    headRow.append(actions);
    head.append(headRow);
    head.append(testResult);
    scroll.append(head);

    const onboarding = onboardingCard();
    if (onboarding) scroll.append(onboarding);

    // macOS detail-column order: info grid → usage → setup → (codex
    // accounts card) → warnings → links.
    scroll.append(detailInfoGrid(selectedId, enabled, st));
    scroll.append(usageSection(selectedId, enabled, st));
    scroll.append(setupSection(cfg, vi));
    if (selectedId === "codex") scroll.append(codexAccountsCard());
    if (selectedId === "freemodel") scroll.append(freemodelAccountsCard());
    if (selectedId === "elevenlabs") scroll.append(elevenlabsKeysCard());
    if (selectedId === "hiyo") scroll.append(hiyoKeysCard());
    scroll.append(quotaWarningCard(selectedId));
    const links = linksSection(selectedId);
    if (links) scroll.append(links);

    // Save
    const saveRow = el("div", "pp-save-row");
    const save = el("button", "save-button", t("settingsSave"));
    save.addEventListener("click", async () => {
      save.textContent = "…";
      try {
        await persistProvidersAndNotify(settings);
        save.textContent = t("settingsSaved");
        setTimeout(onSaved, 300);
        void refreshStatuses().then(() => { renderSidebar(); renderDetail(); });
      } catch (err) {
        save.textContent = `${t("loadError")}: ${err}`;
      }
    });
    saveRow.append(save);
    scroll.append(saveRow);

    detail.append(scroll);
  };

  async function refreshStatuses() {
    try {
      // Fetch all known ids that are enabled (or all) for sidebar subtitles.
      const ids = orderedIds(settings).filter((id) => byId.get(id)?.enabled === true);
      if (ids.length === 0) {
        statuses = [];
        return;
      }
      statuses = await invoke<ProviderStatus[]>("provider_statuses", { ids }).catch(() => []);
    } catch {
      statuses = [];
    }
  }

  // Initial paint + background status fetch
  renderSidebar();
  renderDetail();
  for (const id of ONBOARDING_IDS) {
    void invoke<OnboardingDetection>("provider_onboarding_detection", { id })
      .then((result) => { detections.set(id, result); if (id === selectedId) renderDetail(); })
      .catch(() => {});
  }
  void refreshStatuses().then(() => { renderSidebar(); renderDetail(); });

  return root;
}

/** @deprecated in-popover settings — use open_settings_window + settingsWindowRoot */
export async function settingsTab(onSaved: () => void, onRefreshNow: () => void): Promise<HTMLElement> {
  void onRefreshNow;
  return providersPane(onSaved);
}
