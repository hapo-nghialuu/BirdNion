// Settings → "Claude Code" — port of macOS ClaudeCodePane: 2-pane layout
// with preset backends (MiniMax/DeepSeek/z.ai/Hapo) + custom profiles on the
// left, and the activation panel (power button), scope chooser, remove-env,
// token/base-URL rows, model loader, and 1M toggle on the right.
//
// Persistence mirrors macOS exactly: scope/path save IMMEDIATELY on change;
// models/1M (preset drafts) save only when the power button applies; custom
// profiles autosave per keystroke (debounced here).

import { invoke } from "@tauri-apps/api/core";
import { open as openDialog, ask } from "@tauri-apps/plugin-dialog";
import { t, currentLang } from "./i18n";
import { logoMark } from "./logos";
import { settingsIcon } from "./settings-icons";
import { isClaudeCodeSupported, type ClaudeCodePowerState, type ClaudeCodeState } from "./claude-code";
import { NAME_BY_ID } from "./settings-tab";
import type { ProviderCfg, Settings } from "./settings-provider-detail";

type ProfileEnvRow = { id: string; key: string; value: string };
type ClaudeCodeProfile = {
  id: string;
  name?: string | null;
  baseURL?: string | null;
  token?: string | null;
  tokenEnvKey?: string | null;
  apiKeyHelper?: string | null;
  haikuModel?: string | null;
  sonnetModel?: string | null;
  opusModel?: string | null;
  claudeCodeScope?: string | null;
  claudeCodeProjectPath?: string | null;
  extraEnv?: ProfileEnvRow[];
  /** `"anthropic"` | `"openai"` — macOS `compatibilityMode`. */
  compatibilityMode?: string | null;
  /** OpenAI-compatible upstream (CLIProxyAPI only). JSON: `openAIBaseURL`. */
  openAIBaseURL?: string | null;
  /** JSON: `openAIAPIKey`. */
  openAIAPIKey?: string | null;
  /** `"responses"` or null/undefined for Chat Completions. JSON: `openAIFormat`. */
  openAIFormat?: string | null;
  /** Explicit local-proxy mode (macOS `embeddedLocalProxy`). */
  embeddedLocalProxy?: boolean | null;
  cliProxyBaseURL?: string | null;
  cliProxyAPIKey?: string | null;
  cliProxyManagementKey?: string | null;
  cliProxyAppliedSignature?: string | null;
  /** Link to the Codex counterpart (macOS `codexProfileID`). */
  codexProfileID?: string | null;
};

/** macOS `BirdNionConfigStore.CodexProfile`. */
type CodexProfile = {
  id: string;
  name: string;
  baseURL: string;
  apiKey: string;
  model: string;
  upstreamProtocolRaw?: string | null;
  connectionModeRaw?: string | null;
  cliProxyBaseURL?: string | null;
  cliProxyAPIKey?: string | null;
  cliProxyManagementKey?: string | null;
  cliProxyAppliedSignature?: string | null;
  claudeCodeProfileID?: string | null;
};

type CodexProfileState = {
  state: "active" | "stale" | "ready" | "setup" | string;
  active: boolean;
  current: boolean;
  targetPath: string;
  usesProxy: boolean;
  profileFlag?: string | null;
  connectionLabel?: string | null;
};

type AICodingAgent = "claudeCode" | "codex";

type CCSettings = Omit<Settings, "claudeCodeProfiles" | "codexProfiles"> & {
  claudeCodeProfiles?: ClaudeCodeProfile[];
  codexProfiles?: CodexProfile[];
};

type Selection = { kind: "provider"; cfg: ProviderCfg } | { kind: "profile"; profile: ClaudeCodeProfile };

/** Proxy card state returned by `cli_proxy_status`. */
type ProxyStatus = {
  state: string;
  endpoint: string;
  configurationCurrent: boolean;
  hasUpstream: boolean;
};

/** Wire-protocol selection: anthropic | chat | responses. */
type ApiStandard = "anthropic" | "chat" | "responses";

const PROXY_ENDPOINT = "http://127.0.0.1:24323/v1";

function isOpenAICompatible(p: ClaudeCodeProfile): boolean {
  return clean(p.compatibilityMode) === "openai";
}

/** macOS `usesEmbeddedCLIProxy`: explicit flag, else OpenAI defaults to proxy. */
function usesLocalProxy(p: ClaudeCodeProfile): boolean {
  if (p.embeddedLocalProxy != null) return p.embeddedLocalProxy === true;
  return isOpenAICompatible(p);
}

function apiStandardOf(p: ClaudeCodeProfile): ApiStandard {
  if (!isOpenAICompatible(p)) return "anthropic";
  return clean(p.openAIFormat) === "responses" ? "responses" : "chat";
}

/** Cross-copy field pairs when switching API standard (only if target empty). */
function applyApiStandard(p: ClaudeCodeProfile, next: ApiStandard): void {
  if (next === "anthropic") {
    if (!clean(p.baseURL) && clean(p.openAIBaseURL)) p.baseURL = p.openAIBaseURL;
    if (!clean(p.token) && clean(p.openAIAPIKey)) p.token = p.openAIAPIKey;
    p.openAIFormat = null;
    p.compatibilityMode = "anthropic";
  } else {
    if (!clean(p.openAIBaseURL) && clean(p.baseURL)) p.openAIBaseURL = p.baseURL;
    if (!clean(p.openAIAPIKey) && clean(p.token)) p.openAIAPIKey = p.token;
    p.embeddedLocalProxy = true;
    p.openAIFormat = next === "responses" ? "responses" : null;
    p.compatibilityMode = "openai";
  }
}

function hasUpstream(p: ClaudeCodeProfile): boolean {
  if (isOpenAICompatible(p)) {
    return !!(clean(p.openAIBaseURL) || clean(p.baseURL))
      && !!(clean(p.openAIAPIKey) || clean(p.token));
  }
  return !!(clean(p.baseURL) && clean(p.token));
}

/** Codex protocol helpers (macOS CodexProfile). */
function codexRequiresProxy(p: CodexProfile): boolean {
  const proto = (p.upstreamProtocolRaw ?? "responses").trim();
  return proto !== "responses";
}
function codexUsesProxy(p: CodexProfile): boolean {
  if (codexRequiresProxy(p)) return true;
  return (p.connectionModeRaw ?? "direct").trim() === "local-proxy";
}
function codexHasUpstream(p: CodexProfile): boolean {
  return !!(clean(p.baseURL) && clean(p.apiKey) && clean(p.model));
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const clean = (v: string | null | undefined): string | null => {
  const s = (v ?? "").trim();
  return s.length > 0 ? s : null;
};

/** Preset draft is "fully configured" — macOS `isFullyConfigured`. */
function presetConfigured(cfg: ProviderCfg): boolean {
  return !!(clean(cfg.apiKey) && clean(cfg.claudeHaikuModel)
    && clean(cfg.claudeSonnetModel) && clean(cfg.claudeOpusModel));
}

/** Profile is applyable — macOS `isReady` (proxy only needs upstream). */
function profileReady(p: ClaudeCodeProfile): boolean {
  return hasUpstream(p);
}

function scopeOk(scope: string | null | undefined, path: string | null | undefined): boolean {
  return scope !== "project" || !!clean(path);
}

/** "sk-c••••" mask — 4 leading chars + dots (macOS maskedToken). */
function maskToken(token: string | null | undefined): string {
  const s = clean(token);
  if (!s) return "••••";
  return `${s.slice(0, 4)}••••`;
}

function orderedUnique(values: (string | null | undefined)[]): string[] {
  const out: string[] = [];
  for (const v of values) {
    const s = clean(v);
    if (s && !out.includes(s)) out.push(s);
  }
  return out;
}

/** Pre-fill an empty tier by substring match, else first suggestion —
 * macOS auto-match after model load. */
function matchTier(models: string[], tier: "haiku" | "sonnet" | "opus"): string | null {
  return models.find((m) => m.toLowerCase().includes(tier)) ?? models[0] ?? null;
}

/** "N. <title>" — numbers shift when the proxy step is skipped (macOS stepTitle). */
function stepTitle(n: number, key: string): string {
  return `${n}. ${t(key)}`;
}

/** Upstream credentials for model fetch (OpenAI vs Anthropic fields). */
function upstreamCreds(p: ClaudeCodeProfile): { base: string | null; token: string | null } {
  if (isOpenAICompatible(p)) {
    return {
      base: clean(p.openAIBaseURL) ?? clean(p.baseURL),
      token: clean(p.openAIAPIKey) ?? clean(p.token),
    };
  }
  return { base: clean(p.baseURL), token: clean(p.token) };
}

export async function claudeCodePane(onSaved: () => void): Promise<HTMLElement> {
  void onSaved; // pane persists itself (macOS parity) — no Save button here.
  const vi = currentLang() === "vi";
  void vi;
  const settings = await invoke<CCSettings>("get_settings")
    .catch(() => ({ version: 1, providers: [] as ProviderCfg[] }) as CCSettings);
  settings.claudeCodeProfiles ??= [];
  settings.codexProfiles ??= [];
  const profiles = settings.claudeCodeProfiles;
  const codexProfiles = settings.codexProfiles;

  const eligibleProviders = (): ProviderCfg[] =>
    settings.providers.filter((p) => isClaudeCodeSupported(p.id) && !!clean(p.apiKey));

  // --- persistence -------------------------------------------------------
  const persist = () => invoke("save_settings", { settings }).catch(() => {});
  let saveTimer: ReturnType<typeof setTimeout> | null = null;
  const persistDebounced = () => {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => { saveTimer = null; void persist(); }, 400);
  };

  // --- selection + per-selection model cache -----------------------------
  let selected: Selection | null = null;
  /** Agent picker — only swaps detail sections in place (macOS `detailAgent`). */
  let detailAgent: AICodingAgent = "claudeCode";
  let workingCodex: CodexProfile | null = null;
  let codexModels: string[] = [];
  let codexModelsLoading = false;
  const modelCache = new Map<string, string[]>();
  let modelsLoading = false;
  let statusMsg: { text: string; isError: boolean } | null = null;
  let busy = false;
  /** Feedback line under the local-proxy status card. */
  let proxyFeedback: { text: string; isError: boolean } | null = null;
  let proxyBusy = false;
  /** Sidebar dual-status cache — filled async to avoid blocking first paint. */
  type SideStatus = { line: string; activated: boolean };
  const sideStatusCache = new Map<string, SideStatus>();
  let sideStatusSeq = 0;

  const selKey = () => (selected?.kind === "provider" ? `p:${selected.cfg.id}` : `c:${selected?.profile.id}`);

  const reloadCodexFromDisk = async (id: string) => {
    const fresh = await invoke<CCSettings>("get_settings").catch(() => null);
    if (!fresh?.codexProfiles) return;
    settings.codexProfiles = fresh.codexProfiles;
    codexProfiles.length = 0;
    codexProfiles.push(...fresh.codexProfiles);
    if (fresh.claudeCodeProfiles) {
      settings.claudeCodeProfiles = fresh.claudeCodeProfiles;
      profiles.length = 0;
      profiles.push(...fresh.claudeCodeProfiles);
    }
    if (fresh.providers) settings.providers = fresh.providers;
    const updated = codexProfiles.find((p) => p.id === id);
    if (updated) workingCodex = { ...updated };
  };

  const switchDetailAgent = async (agent: AICodingAgent) => {
    if (agent === detailAgent) return;
    statusMsg = null;
    proxyFeedback = null;
    if (agent === "codex") {
      try {
        if (selected?.kind === "profile") {
          const created = await invoke<CodexProfile>("codex_ensure_counterpart", {
            claudeProfileId: selected.profile.id,
          });
          workingCodex = created;
          selected.profile.codexProfileID = created.id;
          await reloadCodexFromDisk(created.id);
        } else if (selected?.kind === "provider") {
          const created = await invoke<CodexProfile>("codex_ensure_preset", {
            providerId: selected.cfg.id,
          });
          workingCodex = created;
          selected.cfg.codexProfileID = created.id;
          await reloadCodexFromDisk(created.id);
        } else {
          return;
        }
      } catch (err) {
        statusMsg = { text: String(err), isError: true };
        renderDetail();
        return;
      }
      codexModels = [];
    }
    detailAgent = agent;
    renderDetail();
  };

  const agentPickerCard = (profileId: string, header?: string): HTMLElement => {
    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("aiCoding.step.agent")));
    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");
    const row = el("div", "ccp-field-row");
    row.append(el("span", "ccp-form-label", t("aiCoding.target")));
    const seg = el("div", "ccp-seg");
    seg.dataset.profileId = profileId;
    const mk = (agent: AICodingAgent, label: string) => {
      const btn = el(
        "button",
        `ccp-seg-btn${detailAgent === agent ? " active" : ""}`,
        label,
      ) as HTMLButtonElement;
      btn.type = "button";
      btn.addEventListener("click", () => { void switchDetailAgent(agent); });
      return btn;
    };
    seg.append(mk("claudeCode", t("aiCoding.agent.claudeCode")));
    seg.append(mk("codex", t("aiCoding.agent.codex")));
    const trail = el("div", "ccp-field-control");
    trail.append(seg);
    row.append(trail);
    body.append(row);
    card.append(body);
    group.append(card);
    return group;
  };

  const root = el("div", "pp-root ccp-root");
  const sidebar = el("div", "pp-sidebar");
  const detail = el("div", "pp-detail");
  root.append(sidebar, detail);

  const selectProvider = (cfg: ProviderCfg) => {
    selected = { kind: "provider", cfg };
    statusMsg = null;
    proxyFeedback = null;
    detailAgent = "claudeCode";
    workingCodex = null;
    codexModels = [];
    void seedModels(cfg);
    renderAll();
  };
  const selectProfile = (profile: ClaudeCodeProfile) => {
    selected = { kind: "profile", profile };
    statusMsg = null;
    proxyFeedback = null;
    detailAgent = "claudeCode";
    workingCodex = null;
    codexModels = [];
    renderAll();
  };

  /** Pull a profile's cliProxy* fields back from disk after prepare. */
  const reloadProfileFromDisk = async (profile: ClaudeCodeProfile) => {
    const fresh = await invoke<CCSettings>("get_settings").catch(() => null);
    const updated = fresh?.claudeCodeProfiles?.find((p) => p.id === profile.id);
    if (!updated) return;
    Object.assign(profile, updated);
    const idx = profiles.findIndex((p) => p.id === profile.id);
    if (idx >= 0) profiles[idx] = profile;
  };

  // --- sidebar dual status (macOS CC: · CX:) --------------------------------
  const ccStatusLabel = (
    power: ClaudeCodePowerState,
    activated: boolean,
  ): string => {
    if (activated) return t("ccxState.on");
    if (power === "on") return t("ccxState.proxyStopped");
    if (power === "stale") return t("ccxState.stale");
    if (power === "off") return t("ccxState.off");
    return t("ccxState.needsSetup");
  };

  const cxStatusLabel = (st: CodexProfileState | null): string => {
    if (!st) return t("codexConfig.state.setup");
    if (st.state === "active") return t("codexConfig.state.active");
    if (st.state === "stale") return t("codexConfig.state.stale");
    if (st.state === "ready") return t("codexConfig.state.ready");
    return t("codexConfig.state.setup");
  };

  const combinedStatusLine = (cc: string, cx: string | null): string => {
    if (!cx) return `${t("ccxSide.cc")}: ${cc}`;
    return `${t("ccxSide.cc")}: ${cc} · ${t("ccxSide.cx")}: ${cx}`;
  };

  const resolveSideStatus = async (sel: Selection): Promise<SideStatus> => {
    const power = await resolveState(sel);
    let activated = power === "on";
    // Proxy-backed custom profiles: synced env but dead proxy → not activated.
    if (sel.kind === "profile" && usesLocalProxy(sel.profile) && power === "on") {
      const pst = await invoke<ProxyStatus>("cli_proxy_status", {
        profileId: sel.profile.id,
      }).catch(() => null);
      if (!pst || pst.state !== "running") activated = false;
    }
    const cc = ccStatusLabel(power, activated);

    let cx: string | null = null;
    let cxActive = false;
    const codexId = sel.kind === "provider"
      ? clean(sel.cfg.codexProfileID ?? null)
      : clean(sel.profile.codexProfileID);
    if (codexId) {
      const st = await invoke<CodexProfileState>("codex_profile_state", { id: codexId })
        .catch(() => null);
      if (st) {
        cx = cxStatusLabel(st);
        cxActive = st.state === "active" || st.active === true;
      } else {
        cx = t("codexConfig.state.setup");
      }
    }
    return { line: combinedStatusLine(cc, cx), activated: activated || cxActive };
  };

  const paintSideRow = (
    row: HTMLElement,
    key: string,
    name: string,
    leading: HTMLElement,
  ) => {
    const cached = sideStatusCache.get(key);
    const textCol = el("div", "ccp-side-text");
    textCol.append(el("div", "ccp-side-name", name));
    const statusEl = el(
      "div",
      `ccp-side-status${cached?.activated ? " activated" : ""}`,
      cached?.line ?? "…",
    );
    textCol.append(statusEl);
    row.append(leading, textCol);
    const dot = el("span", `ccp-side-dot${cached?.activated ? " activated" : ""}`);
    row.append(dot);
    if (cached?.activated) row.classList.add("ccp-activated");
  };

  const refreshSideStatuses = () => {
    const seq = ++sideStatusSeq;
    const jobs: Array<{ key: string; sel: Selection }> = [];
    for (const cfg of eligibleProviders()) {
      jobs.push({ key: `p:${cfg.id}`, sel: { kind: "provider", cfg } });
    }
    for (const profile of profiles) {
      jobs.push({ key: `c:${profile.id}`, sel: { kind: "profile", profile } });
    }
    void (async () => {
      // Parallel batch — avoid N serial IPC round-trips on the sidebar.
      await Promise.all(jobs.map(async ({ key, sel }) => {
        try {
          sideStatusCache.set(key, await resolveSideStatus(sel));
        } catch {
          sideStatusCache.set(key, {
            line: combinedStatusLine(t("ccxState.needsSetup"), null),
            activated: false,
          });
        }
      }));
      if (seq !== sideStatusSeq) return;
      renderSidebar(false);
    })();
  };

  // --- sidebar ------------------------------------------------------------
  const renderSidebar = (kickRefresh = true) => {
    sidebar.textContent = "";
    sidebar.append(el("div", "ccp-hint", t("ccxSelectProvider")));

    const list = el("div", "pp-sidebar-list");
    for (const cfg of eligibleProviders()) {
      const isSel = selected?.kind === "provider" && selected.cfg.id === cfg.id;
      const row = el("div", `pp-side-row${isSel ? " selected" : ""}`);
      paintSideRow(
        row,
        `p:${cfg.id}`,
        cfg.displayName?.trim() || NAME_BY_ID.get(cfg.id) || cfg.id,
        logoMark(cfg.id, "pp-side-logo tab-logo-mono pp-logo-on"),
      );
      row.addEventListener("click", () => selectProvider(cfg));
      list.append(row);
    }
    sidebar.append(list);

    // "TUỲ CHỈNH" + add button
    const head = el("div", "ccp-custom-head");
    head.append(el("span", "sw-section-header", t("ccxCustomSection")));
    const add = el("button", "sw-icon-btn ccp-add", "+");
    add.title = t("ccxAddConfig");
    add.addEventListener("click", () => {
      const profile: ClaudeCodeProfile = {
        id: crypto.randomUUID(),
        name: t("ccxNewConfig"),
        tokenEnvKey: "ANTHROPIC_AUTH_TOKEN",
        extraEnv: [],
      };
      profiles.push(profile);
      void persist();
      selectProfile(profile);
    });
    head.append(add);
    sidebar.append(head);

    const plist = el("div", "pp-sidebar-list");
    for (const profile of profiles) {
      const isSel = selected?.kind === "profile" && selected.profile.id === profile.id;
      const row = el("div", `pp-side-row${isSel ? " selected" : ""}`);
      const icon = el("span", "ccp-profile-icon");
      icon.append(settingsIcon("terminal", "ccp-profile-svg"));
      paintSideRow(
        row,
        `c:${profile.id}`,
        clean(profile.name) ?? t("ccxNewConfig"),
        icon,
      );
      row.addEventListener("click", () => selectProfile(profile));
      plist.append(row);
    }
    sidebar.append(plist);
    if (kickRefresh) refreshSideStatuses();
  };

  // --- shared detail helpers ----------------------------------------------
  const stateBadge = (state: ClaudeCodePowerState): HTMLElement => {
    const badge = el("span", `ccp-badge ccp-badge-${state}`);
    const glyph = state === "on" ? "✓" : state === "stale" ? "↻" : state === "needsSetup" ? "!" : "⏻";
    badge.append(el("span", "ccp-badge-glyph", glyph));
    badge.append(document.createTextNode(t(`ccxState.${state}`)));
    return badge;
  };

  const subtitleFor = (state: ClaudeCodePowerState, sel: Selection, name: string): string => {
    if (state === "on") return t("ccxSubOn", { name });
    if (state === "stale") return t("ccxSubStale");
    if (state === "off") {
      if (sel.kind === "profile" && usesLocalProxy(sel.profile)) return t("ccxProxyTapToStart");
      return t("ccxSubOff");
    }
    const scope = sel.kind === "provider" ? sel.cfg.claudeCodeScope : sel.profile.claudeCodeScope;
    const path = sel.kind === "provider" ? sel.cfg.claudeCodeProjectPath : sel.profile.claudeCodeProjectPath;
    if (!scopeOk(scope, path)) return t("ccxSubNeedDir");
    if (sel.kind === "provider") return t("ccxSubNeedModels");
    return usesLocalProxy(sel.profile) ? t("ccxNeedProxyConfig") : t("ccxSubNeedBase");
  };

  const targetLabel = (sel: Selection): string => {
    const scope = sel.kind === "provider" ? sel.cfg.claudeCodeScope : sel.profile.claudeCodeScope;
    const path = sel.kind === "provider" ? sel.cfg.claudeCodeProjectPath : sel.profile.claudeCodeProjectPath;
    if (scope !== "project") return t("ccxTargetGlobal");
    const dir = clean(path);
    return dir ? `${dir}/.claude/settings.json` : t("ccxSubNeedDir");
  };

  /** Disk state from Rust, gated by the in-memory draft like macOS (an
   * unsaved-but-complete draft shows "off", not "needsSetup"). */
  const resolveState = async (sel: Selection): Promise<ClaudeCodePowerState> => {
    const scope = sel.kind === "provider" ? sel.cfg.claudeCodeScope : sel.profile.claudeCodeScope;
    const path = sel.kind === "provider" ? sel.cfg.claudeCodeProjectPath : sel.profile.claudeCodeProjectPath;
    const configured = (sel.kind === "provider" ? presetConfigured(sel.cfg) : profileReady(sel.profile))
      && scopeOk(scope, path);
    if (!configured) return "needsSetup";
    try {
      const st = sel.kind === "provider"
        ? await invoke<ClaudeCodeState>("claude_code_state", { providerId: sel.cfg.id })
        : await invoke<ClaudeCodeState>("claude_code_profile_state", { profileId: sel.profile.id });
      return st.state === "needsSetup" ? "off" : st.state;
    } catch {
      return "off";
    }
  };

  // --- activation panel ----------------------------------------------------
  const activationPanel = (sel: Selection, state: ClaudeCodePowerState): HTMLElement => {
    const name = sel.kind === "provider"
      ? (sel.cfg.displayName?.trim() || NAME_BY_ID.get(sel.cfg.id) || sel.cfg.id)
      : (clean(sel.profile.name) ?? t("ccxNewConfig"));
    const card = el("div", "sw-card ccp-activation");
    const row = el("div", "ccp-act-row");

    const iconBox = el("div", `ccp-act-icon ccp-act-${state}`);
    iconBox.append(settingsIcon("terminal", "ccp-act-svg"));
    row.append(iconBox);

    const body = el("div", "ccp-act-body");
    const titleRow = el("div", "ccp-act-title-row");
    titleRow.append(el("span", "ccp-act-title", sel.kind === "provider" ? t("ccxBackendTitle") : name));
    titleRow.append(stateBadge(state));
    body.append(titleRow);
    body.append(el("div", "ccp-act-sub", subtitleFor(state, sel, name)));
    const target = el("div", "ccp-act-target", targetLabel(sel));
    target.title = targetLabel(sel);
    body.append(target);
    if (sel.kind === "provider") {
      const acc = el("div", "ccp-act-provider");
      acc.append(logoMark(sel.cfg.id, "ccp-act-logo"));
      acc.append(el("span", "ccp-act-provider-name", name));
      body.append(acc);
    }
    row.append(body);

    const power = document.createElement("button");
    power.type = "button";
    power.className = `cc-power cc-power-${state} cc-power-lg${busy ? " cc-power-busy" : ""}`;
    power.title = subtitleFor(state, sel, name);
    if (busy) {
      power.disabled = true;
      power.append(el("span", "cc-power-spinner", ""));
    } else {
      power.append(settingsIcon("power", "cc-power-icon"));
      if (state === "needsSetup" || state === "stale") power.append(el("span", "cc-power-dot", ""));
    }
    power.addEventListener("click", () => { void onPowerTap(sel, state); });
    row.append(power);

    card.append(row);
    return card;
  };

  const onPowerTap = async (sel: Selection, state: ClaudeCodePowerState) => {
    if (busy || state === "needsSetup") return;
    busy = true;
    renderDetail();
    try {
      if (state === "on") {
        if (sel.kind === "provider") await invoke("claude_code_deactivate", { providerId: sel.cfg.id });
        else await invoke("claude_code_profile_deactivate", { profileId: sel.profile.id });
        statusMsg = { text: t("ccxDeactivated"), isError: false };
      } else {
        // Save the draft first (models/1M persist at power time — macOS).
        await persist();
        if (sel.kind === "provider") {
          await invoke("claude_code_apply", { providerId: sel.cfg.id });
        } else {
          // Full activation: ensure local proxy is running + current before apply.
          if (usesLocalProxy(sel.profile)) {
            const st = await invoke<ProxyStatus>("cli_proxy_status", {
              profileId: sel.profile.id,
            }).catch(() => null);
            if (!st || st.state !== "running" || !st.configurationCurrent) {
              await invoke<ProxyStatus>("cli_proxy_prepare", { profileId: sel.profile.id });
              await reloadProfileFromDisk(sel.profile);
            }
          }
          await invoke("claude_code_profile_apply", { profileId: sel.profile.id });
        }
        statusMsg = state === "stale"
          ? { text: t("ccxUpdated"), isError: false }
          : { text: t("ccxSaved", { path: targetLabel(sel) }), isError: false };
      }
    } catch (err) {
      statusMsg = { text: String(err), isError: true };
    }
    busy = false;
    renderAll();
  };

  // --- scope / remove-env card ---------------------------------------------
  const scopeCard = (sel: Selection): HTMLElement => {
    const isProvider = sel.kind === "provider";
    const getScope = () => (isProvider ? sel.cfg.claudeCodeScope : sel.profile.claudeCodeScope) === "project" ? "project" : "global";
    const setScope = (v: "global" | "project") => {
      if (isProvider) sel.cfg.claudeCodeScope = v === "global" ? null : v;
      else sel.profile.claudeCodeScope = v === "global" ? null : v;
    };
    const getPath = () => clean(isProvider ? sel.cfg.claudeCodeProjectPath : sel.profile.claudeCodeProjectPath);
    const setPath = (v: string | null) => {
      if (isProvider) sel.cfg.claudeCodeProjectPath = v;
      else sel.profile.claudeCodeProjectPath = v;
    };

    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");

    // Segmented scope picker — persists immediately (macOS behavior).
    const row = el("div", "pp-field-row");
    row.append(el("span", "pp-field-label ccp-strong", t("ccxScope")));
    const seg = el("div", "ccp-seg");
    const mkSeg = (value: "global" | "project", label: string) => {
      const b = el("button", `ccp-seg-btn${getScope() === value ? " active" : ""}`, label);
      b.addEventListener("click", () => {
        setScope(value);
        void persist();
        renderAll();
      });
      return b;
    };
    seg.append(mkSeg("global", t("ccxScopeGlobal")), mkSeg("project", t("ccxScopeProject")));
    row.append(seg);
    body.append(row);
    if (getScope() === "global") {
      body.append(el("div", "pp-field-hint", t("ccxGlobalNote")));
    } else {
      const prow = el("div", "pp-field-row");
      const pathEl = el("span", `ccp-path${getPath() ? "" : " empty"}`, getPath() ?? t("ccxSubNeedDir"));
      pathEl.title = getPath() ?? "";
      prow.append(pathEl);
      const chooseBtn = el("button", "sw-pill-btn", t("ccxChoose"));
      chooseBtn.addEventListener("click", async () => {
        const dir = await openDialog({ directory: true, multiple: false }).catch(() => null);
        if (typeof dir === "string" && dir) {
          setPath(dir);
          void persist();
          renderAll();
        }
      });
      prow.append(chooseBtn);
      body.append(prow);
      body.append(el("div", "pp-field-hint", t("ccxProjectNote")));
    }

    // Remove env row + confirm.
    const rrow = el("div", "pp-field-row");
    const rtext = el("div", "ccp-remove-text");
    rtext.append(el("div", "ccp-strong", t("ccxRemoveEnvTitle")));
    rtext.append(el("div", "pp-field-hint ccp-nopad", t("ccxRemoveEnvSub", { path: targetLabel(sel) })));
    rrow.append(rtext);
    const rbtn = el("button", "sw-pill-btn ccp-danger", t("ccxRemoveEnv"));
    rbtn.addEventListener("click", async () => {
      const ok = await ask(t("ccxRemoveEnvConfirm", { path: targetLabel(sel) }), {
        title: t("ccxRemoveEnvTitle"),
        kind: "warning",
      }).catch(() => false);
      if (!ok) return;
      try {
        const removed = isProvider
          ? await invoke<boolean>("claude_code_remove_env", { providerId: sel.cfg.id })
          : await invoke<boolean>("claude_code_profile_remove_env", { profileId: sel.profile.id });
        statusMsg = {
          text: removed ? t("ccxRemoveEnvDone", { path: targetLabel(sel) }) : t("ccxRemoveEnvNone"),
          isError: false,
        };
      } catch (err) {
        statusMsg = { text: String(err), isError: true };
      }
      renderAll();
    });
    rrow.append(rbtn);
    body.append(rrow);

    // Preset-only read-only rows: Token + Base URL.
    if (isProvider) {
      const name = sel.cfg.displayName?.trim() || NAME_BY_ID.get(sel.cfg.id) || sel.cfg.id;
      const trow = el("div", "pp-field-row");
      trow.append(el("span", "pp-field-label ccp-strong", t("ccxToken")));
      trow.append(el("span", "ccp-mono", `${t("ccxTokenOf", { name })} · ${maskToken(sel.cfg.apiKey)}`));
      body.append(trow);
      const brow = el("div", "pp-field-row");
      brow.append(el("span", "pp-field-label ccp-strong", t("ccxBaseUrl")));
      const burl = el("span", "ccp-mono", "…");
      brow.append(burl);
      body.append(brow);
      if (sel.cfg.id === "hapo") {
        // The Hapo endpoint is private (baked at build time) — never render it.
        burl.textContent = "••••";
      } else {
        void invoke<{ baseUrl: string | null }>("claude_code_backend_info", { providerId: sel.cfg.id })
          .then((info) => { burl.textContent = info.baseUrl ?? "—"; })
          .catch(() => { burl.textContent = "—"; });
      }
    }

    card.append(body);
    return card;
  };

  // --- model card ------------------------------------------------------------
  const modelCard = (sel: Selection, header?: string): HTMLElement => {
    const key = selKey();
    const models = modelCache.get(key) ?? [];
    const getTier = (tier: "haiku" | "sonnet" | "opus"): string =>
      (sel.kind === "provider"
        ? { haiku: sel.cfg.claudeHaikuModel, sonnet: sel.cfg.claudeSonnetModel, opus: sel.cfg.claudeOpusModel }[tier]
        : { haiku: sel.profile.haikuModel, sonnet: sel.profile.sonnetModel, opus: sel.profile.opusModel }[tier]) ?? "";
    const setTier = (tier: "haiku" | "sonnet" | "opus", v: string | null) => {
      if (sel.kind === "provider") {
        if (tier === "haiku") sel.cfg.claudeHaikuModel = v;
        else if (tier === "sonnet") sel.cfg.claudeSonnetModel = v;
        else sel.cfg.claudeOpusModel = v;
      } else {
        if (tier === "haiku") sel.profile.haikuModel = v;
        else if (tier === "sonnet") sel.profile.sonnetModel = v;
        else sel.profile.opusModel = v;
        persistDebounced();
      }
    };

    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("ccxModelSection")));
    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");

    // Header row: count + load button.
    const head = el("div", "pp-field-row");
    head.append(el("span", "pp-field-hint ccp-nopad",
      modelsLoading ? t("ccxModelsLoading") : t("ccxModelsLoaded", { n: models.length })));
    const loadBtn = el("button", "sw-pill-btn", models.length > 0 ? t("ccxReloadModels") : t("ccxLoadModels"));
    if (modelsLoading) loadBtn.setAttribute("disabled", "true");
    loadBtn.addEventListener("click", async () => {
      let base: string | null = null;
      let token: string | null = null;
      if (sel.kind === "provider") {
        token = clean(sel.cfg.apiKey);
        const info = await invoke<{ baseUrl: string | null }>("claude_code_backend_info", { providerId: sel.cfg.id }).catch(() => null);
        base = info?.baseUrl ?? null;
      } else {
        // OpenAI profiles use openAI* fields; Anthropic uses baseURL/token.
        ({ base, token } = upstreamCreds(sel.profile));
      }
      if (!base || !token) {
        // Silent guard — match macOS (no red banner when creds missing).
        return;
      }
      modelsLoading = true;
      renderDetail();
      try {
        const fetched = await invoke<string[]>("claude_code_models", { baseUrl: base, token });
        const merged = orderedUnique([...fetched, ...models]);
        modelCache.set(key, merged);
        // Auto-match empty tiers (macOS behavior after load).
        for (const tier of ["haiku", "sonnet", "opus"] as const) {
          if (!clean(getTier(tier))) setTier(tier, matchTier(merged, tier));
        }
        statusMsg = null;
      } catch (err) {
        statusMsg = { text: String(err), isError: true };
      }
      modelsLoading = false;
      renderDetail();
    });
    head.append(loadBtn);
    body.append(head);

    // 3 tier rows: label 62px + mono input + suggestion select.
    for (const tier of ["haiku", "sonnet", "opus"] as const) {
      const row = el("div", "pp-field-row ccp-model-row");
      row.append(el("span", "ccp-model-label", tier.charAt(0).toUpperCase() + tier.slice(1)));
      const input = document.createElement("input");
      input.type = "text";
      input.className = "settings-input ccp-model-input";
      input.placeholder = t("ccxModelPlaceholder");
      input.value = getTier(tier);
      input.addEventListener("change", () => setTier(tier, clean(input.value)));
      row.append(input);
      const pick = document.createElement("select");
      pick.className = "ccp-model-pick";
      pick.title = "";
      const blank = document.createElement("option");
      blank.value = "";
      blank.textContent = "▾";
      pick.append(blank);
      for (const m of orderedUnique([getTier(tier), ...models])) {
        const o = document.createElement("option");
        o.value = m;
        o.textContent = m;
        pick.append(o);
      }
      if (models.length === 0 && !clean(getTier(tier))) pick.setAttribute("disabled", "true");
      pick.addEventListener("change", () => {
        if (pick.value) {
          input.value = pick.value;
          setTier(tier, pick.value);
        }
        pick.value = "";
      });
      row.append(pick);
      body.append(row);
    }

    card.append(body);
    group.append(card);
    return group;
  };

  // --- preset 1M toggle -------------------------------------------------------
  const disable1MCard = (cfg: ProviderCfg): HTMLElement => {
    const card = el("div", "sw-card");
    const row = el("div", "pp-field-row");
    row.append(el("span", "pp-field-label ccp-strong", t("ccxDisable1M")));
    const toggle = document.createElement("input");
    toggle.type = "checkbox";
    toggle.className = "sw-switch";
    toggle.checked = cfg.claudeDisable1M === true;
    toggle.addEventListener("change", () => { cfg.claudeDisable1M = toggle.checked; });
    row.append(toggle);
    card.append(row);
    return card;
  };

  // --- local proxy status card (macOS ClaudeCodeLocalProxyStatusCard) --------
  const proxyStatusCard = (
    profile: ClaudeCodeProfile,
    st: ProxyStatus | null,
    header?: string,
  ): HTMLElement => {
    const state = st?.state ?? "checking";
    const upstreamOk = st?.hasUpstream ?? hasUpstream(profile);
    const current = st?.configurationCurrent ?? false;
    const endpoint = st?.endpoint || PROXY_ENDPOINT;

    type Action = "start" | "update" | "retry" | "stop" | "waiting";
    let action: Action = "start";
    if (!upstreamOk) action = "start";
    else if (state === "running") action = current ? "stop" : "update";
    else if (state === "failed") action = "retry";
    else if (state === "checking" || state === "starting") action = "waiting";
    else action = "start";

    const presentation = (() => {
      if (!upstreamOk) {
        return {
          tone: "warn",
          title: t("ccxProxyStatusNeedsConfig"),
          detail: t("ccxProxyDetailNeedsConfig"),
        };
      }
      switch (state) {
        case "checking":
          return { tone: "muted", title: t("ccxProxyStatusChecking"), detail: t("ccxProxyDetailChecking") };
        case "starting":
          return { tone: "accent", title: t("ccxProxyStatusStarting"), detail: t("ccxProxyDetailStarting") };
        case "running":
          return current
            ? { tone: "ok", title: t("ccxProxyStatusRunning"), detail: t("ccxProxyDetailRunning") }
            : { tone: "warn", title: t("ccxProxyStatusNeedsUpdate"), detail: t("ccxProxyDetailNeedsUpdate") };
        case "failed":
          return { tone: "err", title: t("ccxProxyStatusFailed"), detail: t("ccxProxyDetailFailed") };
        default:
          return { tone: "muted", title: t("ccxProxyStatusStopped"), detail: t("ccxProxyDetailStopped") };
      }
    })();

    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("ccx.step.proxy")));
    const card = el("div", "sw-card ccp-proxy-card");
    const head = el("div", "ccp-proxy-head");

    const icon = el("div", `ccp-proxy-icon ccp-proxy-tone-${presentation.tone}`);
    icon.textContent = presentation.tone === "ok" ? "✓" : presentation.tone === "err" ? "!" : presentation.tone === "warn" ? "↻" : "●";
    head.append(icon);

    const body = el("div", "ccp-proxy-body");
    body.append(el("div", "ccp-proxy-title", presentation.title));
    body.append(el("div", "ccp-proxy-detail", presentation.detail));
    head.append(body);

    const actions = el("div", "ccp-proxy-actions");
    if (action === "waiting" || proxyBusy) {
      actions.append(el("span", "cc-power-spinner ccp-proxy-spinner", ""));
    } else if (action === "stop") {
      const stopBtn = el("button", "sw-pill-btn ccp-danger", t("ccxProxyStop"));
      stopBtn.addEventListener("click", async () => {
        const ok = await ask(t("ccxProxyStopConfirmMessage"), {
          title: t("ccxProxyStopConfirmTitle"),
          kind: "warning",
        }).catch(() => false);
        if (!ok) return;
        proxyBusy = true;
        renderDetail();
        try {
          const stopped = await invoke<boolean>("cli_proxy_stop");
          proxyFeedback = {
            text: stopped ? t("ccxProxyStopDone") : t("ccxProxyStopNone"),
            isError: false,
          };
        } catch (err) {
          proxyFeedback = { text: String(err), isError: true };
        }
        proxyBusy = false;
        renderDetail();
      });
      actions.append(stopBtn);
    } else {
      const label = action === "update" ? t("ccxProxyUpdate")
        : action === "retry" ? t("ccxProxyRetry")
          : t("ccxProxyStart");
      const startBtn = el("button", "sw-pill-btn ccp-primary", label) as HTMLButtonElement;
      startBtn.disabled = !upstreamOk;
      startBtn.addEventListener("click", async () => {
        if (!upstreamOk) return;
        proxyBusy = true;
        proxyFeedback = null;
        renderDetail();
        try {
          await persist();
          await invoke<ProxyStatus>("cli_proxy_prepare", { profileId: profile.id });
          await reloadProfileFromDisk(profile);
          proxyFeedback = { text: t("ccxProxyStarted"), isError: false };
        } catch (err) {
          proxyFeedback = { text: String(err), isError: true };
        }
        proxyBusy = false;
        renderDetail();
      });
      actions.append(startBtn);
    }

    const refreshBtn = el("button", "sw-icon-btn", "↻") as HTMLButtonElement;
    refreshBtn.title = t("ccxProxyRefresh");
    refreshBtn.disabled = proxyBusy || state === "starting";
    refreshBtn.addEventListener("click", () => {
      proxyFeedback = null;
      renderDetail();
    });
    actions.append(refreshBtn);
    head.append(actions);
    card.append(head);

    card.append(el("div", "ccp-row-divider"));

    const epRow = el("div", "ccp-proxy-endpoint-row");
    epRow.append(el("span", "ccp-proxy-ep-label", t("ccxProxyLocalEndpoint")));
    epRow.append(el("span", "ccp-proxy-ep-value ccp-mono", endpoint));
    const copyBtn = el("button", "sw-icon-btn", "⎘");
    copyBtn.title = t("ccxProxyCopyEndpoint");
    copyBtn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(endpoint);
        proxyFeedback = { text: t("ccxProxyCopyEndpoint"), isError: false };
        renderDetail();
      } catch {
        /* ignore */
      }
    });
    epRow.append(copyBtn);
    card.append(epRow);

    if (proxyFeedback) {
      card.append(el("div", "ccp-row-divider"));
      card.append(el(
        "div",
        `ccp-proxy-feedback${proxyFeedback.isError ? " error" : ""}`,
        proxyFeedback.text,
      ));
    }

    group.append(card);
    return group;
  };

  // --- custom profile form (macOS ClaudeCodeCustomProfileForm) ---------------
  const profileForm = (
    profile: ClaudeCodeProfile,
    mode: { upstreamOnly?: boolean; claudeOnly?: boolean } = {},
  ): HTMLElement => {
    const wrap = el("div", "ccp-form");
    const proxyMode = usesLocalProxy(profile);
    const openAI = isOpenAICompatible(profile);
    const standard = apiStandardOf(profile);
    const showUpstream = !mode.claudeOnly;
    const showClaudeExtra = !mode.upstreamOnly;

    const fieldRow = (label: string, control: HTMLElement) => {
      const row = el("div", "ccp-field-row");
      row.append(el("span", "ccp-form-label", label));
      const trail = el("div", "ccp-field-control");
      trail.append(control);
      row.append(trail);
      return row;
    };
    const divider = () => el("div", "ccp-row-divider");
    const textField = (
      value: string | null | undefined, placeholder: string,
      onChange: (v: string | null) => void, opts: { mono?: boolean; password?: boolean } = {},
    ) => {
      const input = document.createElement("input");
      input.type = opts.password ? "password" : "text";
      input.placeholder = placeholder;
      input.value = value ?? "";
      input.className = `ccp-input${opts.mono ? " ccp-mono" : ""}`;
      input.addEventListener("input", () => {
        onChange(clean(input.value));
        persistDebounced();
        // Clear stale error banner on edit (parity with SwiftUI auto-reset).
        // Re-render only when an error was present to avoid focus loss.
        if (statusMsg?.isError) {
          statusMsg = null;
          renderDetail();
        }
      });
      return input;
    };
    const secretField = (
      value: string | null | undefined,
      onChange: (v: string | null) => void,
    ) => {
      const tokenWrap = el("div", "ccp-token-wrap");
      const tokenInput = textField(value, "sk-…", onChange, { password: true, mono: true });
      const eye = el("button", "sw-icon-btn ccp-eye");
      eye.title = t("ccxShowToken");
      eye.append(settingsIcon("eye", "ccp-eye-svg"));
      eye.addEventListener("click", () => {
        const showing = tokenInput.type === "text";
        tokenInput.type = showing ? "password" : "text";
        eye.title = showing ? t("ccxShowToken") : t("ccxHideToken");
        eye.replaceChildren(settingsIcon(showing ? "eye" : "eye.slash", "ccp-eye-svg"));
      });
      tokenWrap.append(tokenInput, eye);
      return tokenWrap;
    };

    if (showUpstream) {
      // Card 1: name → API standard → connection (Anthropic only) → upstream fields
      const c1 = el("div", "sw-card");
      const b1 = el("div", "sw-card-body");

      b1.append(fieldRow(t("ccxName"), textField(profile.name, t("ccxNamePlaceholder"), (v) => {
        profile.name = v;
        renderSidebar();
      })));
      b1.append(divider());

      // Segmented "API standard" — Anthropic / OpenAI Chat / OpenAI Responses.
      const stdBlock = el("div", "ccp-std-block");
      stdBlock.append(el("div", "ccp-std-label", t("ccxCompatibility")));
      const stdSeg = el("div", "ccp-seg ccp-seg-std");
      const mkStd = (modeStd: ApiStandard, label: string) => {
        const btn = el("button", `ccp-seg-btn${standard === modeStd ? " active" : ""}`, label) as HTMLButtonElement;
        btn.type = "button";
        btn.addEventListener("click", () => {
          if (apiStandardOf(profile) === modeStd) return;
          applyApiStandard(profile, modeStd);
          profile.cliProxyAppliedSignature = null;
          proxyFeedback = null;
          persistDebounced();
          renderDetail();
        });
        return btn;
      };
      stdSeg.append(mkStd("anthropic", t("ccxProtocolAnthropic")));
      stdSeg.append(mkStd("chat", t("ccxProtocolOpenAIChat")));
      stdSeg.append(mkStd("responses", t("ccxProtocolResponses")));
      stdBlock.append(stdSeg);
      stdBlock.append(el("div", "ccp-std-hint", t("ccxCompatibilityHint")));
      b1.append(stdBlock);
      b1.append(divider());

      // Connection picker only for Anthropic — OpenAI always uses local proxy.
      // Lives in the upstream card so breadcrumb step 1 stays complete when
      // the form is split (upstreamOnly / claudeOnly).
      if (!openAI) {
        const connSeg = el("div", "ccp-seg");
        const mkConn = (modeConn: "direct" | "proxy", label: string) => {
          const btn = el("button", `ccp-seg-btn${(modeConn === "proxy") === proxyMode ? " active" : ""}`, label) as HTMLButtonElement;
          btn.type = "button";
          btn.addEventListener("click", () => {
            const next = modeConn === "proxy";
            if ((profile.embeddedLocalProxy === true) === next) return;
            if (profile.compatibilityMode == null) {
              profile.compatibilityMode = "anthropic";
            }
            profile.embeddedLocalProxy = next;
            if (!next) profile.cliProxyAppliedSignature = null;
            proxyFeedback = null;
            persistDebounced();
            renderDetail();
          });
          return btn;
        };
        connSeg.append(mkConn("direct", t("ccxConnectionDirect")));
        connSeg.append(mkConn("proxy", t("ccxConnectionProxy")));
        b1.append(fieldRow(t("ccxConnection"), connSeg));
        b1.append(divider());
      }

      if (openAI) {
        b1.append(fieldRow(
          t("ccxOpenAIBaseUrl"),
          textField(profile.openAIBaseURL, "https://api.example.com/v1", (v) => {
            profile.openAIBaseURL = v;
          }, { mono: true }),
        ));
        b1.append(divider());
        b1.append(fieldRow(
          t("ccxOpenAIApiKey"),
          secretField(profile.openAIAPIKey, (v) => { profile.openAIAPIKey = v; }),
        ));
      } else {
        b1.append(fieldRow(t("ccxBaseUrl"), textField(profile.baseURL, "https://api.example.com", (v) => {
          profile.baseURL = v;
        }, { mono: true })));
        b1.append(divider());
        b1.append(fieldRow(t("ccxToken"), secretField(profile.token, (v) => { profile.token = v; })));
        if (!proxyMode && showClaudeExtra) {
          b1.append(divider());
          const kindPick = document.createElement("select");
          kindPick.className = "ccp-input ccp-select ccp-mono";
          for (const k of ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]) {
            const o = document.createElement("option");
            o.value = k;
            o.textContent = k;
            kindPick.append(o);
          }
          kindPick.value = profile.tokenEnvKey === "ANTHROPIC_API_KEY" ? "ANTHROPIC_API_KEY" : "ANTHROPIC_AUTH_TOKEN";
          kindPick.addEventListener("change", () => {
            profile.tokenEnvKey = kindPick.value;
            persistDebounced();
          });
          b1.append(fieldRow(t("ccxTokenKind"), kindPick));
        }
      }
      c1.append(b1);
      wrap.append(c1);
    }

    if (showClaudeExtra) {
      // Models come from modelCard() in the parent render (Load models + tiers).
      // Card: ADVANCED — apiKeyHelper + extra env
      const g3 = el("div", "sw-group");
      g3.append(el("div", "sw-section-header", t("ccxAdvanced")));
      const c3 = el("div", "sw-card");
      const b3 = el("div", "sw-card-body");
      b3.append(fieldRow("apiKeyHelper", textField(profile.apiKeyHelper, t("ccxHelperPlaceholder"), (v) => {
        profile.apiKeyHelper = v;
      }, { mono: true })));
      b3.append(divider());

      const envBlock = el("div", "ccp-env-block");
      envBlock.append(el("div", "ccp-env-title", t("ccxExtraEnv")));
      const envWrap = el("div", "ccp-env-list");
      const renderEnvRows = () => {
        envWrap.textContent = "";
        profile.extraEnv ??= [];
        for (const row of profile.extraEnv) {
          const line = el("div", "ccp-env-row");
          const k = textField(row.key, "KEY", (v) => { row.key = v ?? ""; }, { mono: true });
          k.classList.add("ccp-env-key");
          const v = textField(row.value, "value", (val) => { row.value = val ?? ""; }, { mono: true });
          v.classList.add("ccp-env-val");
          const del = el("button", "sw-icon-btn ccp-danger", "−");
          del.title = t("ccxDeleteConfig");
          del.addEventListener("click", () => {
            profile.extraEnv = (profile.extraEnv ?? []).filter((r) => r.id !== row.id);
            persistDebounced();
            renderEnvRows();
          });
          line.append(k, el("span", "ccp-env-eq", "="), v, del);
          envWrap.append(line);
        }
        const addEnv = el("button", "sw-pill-btn ccp-add-env", `+ ${t("ccxAddEnv")}`);
        addEnv.addEventListener("click", () => {
          (profile.extraEnv ??= []).push({ id: crypto.randomUUID(), key: "", value: "" });
          persistDebounced();
          renderEnvRows();
        });
        envWrap.append(addEnv);
      };
      renderEnvRows();
      envBlock.append(envWrap);
      b3.append(envBlock);
      c3.append(b3);
      g3.append(c3);
      wrap.append(g3);

      // Footer: delete only (paste sits above the form — macOS layout).
      const foot = el("div", "ccp-form-foot");
      const delBtn = el("button", "sw-pill-btn ccp-danger", t("ccxDeleteConfig"));
      delBtn.addEventListener("click", async () => {
        const ok = await ask(t("ccxDeleteConfig") + "?", { title: t("ccxDeleteConfig"), kind: "warning" }).catch(() => false);
        if (!ok) return;
        // Dual-record delete when linked Codex exists.
        if (clean(profile.codexProfileID)) {
          try {
            await invoke("codex_delete", {
              id: profile.codexProfileID,
              deleteLinkedClaude: true,
            });
          } catch { /* fall through to local remove */ }
        }
        settings.claudeCodeProfiles = profiles.filter((p) => p.id !== profile.id);
        profiles.length = 0;
        profiles.push(...(settings.claudeCodeProfiles ?? []));
        if (profile.codexProfileID) {
          settings.codexProfiles = codexProfiles.filter((p) => p.id !== profile.codexProfileID);
          codexProfiles.length = 0;
          codexProfiles.push(...(settings.codexProfiles ?? []));
        }
        void persist();
        selected = null;
        const first = eligibleProviders()[0];
        if (first) selectProvider(first);
        else renderAll();
      });
      foot.append(delBtn);
      wrap.append(foot);
    }

    return wrap;
  };

  // --- paste JSON modal --------------------------------------------------------
  const openPasteModal = (profile: ClaudeCodeProfile) => {
    const overlay = el("div", "ccp-modal-overlay");
    const modal = el("div", "ccp-modal");
    modal.append(el("div", "ccp-modal-title", t("ccxPasteTitle")));
    modal.append(el("div", "pp-field-hint ccp-nopad", t("ccxPasteHint")));
    const ta = document.createElement("textarea");
    ta.className = "ccp-modal-text ccp-mono";
    modal.append(ta);
    const errLine = el("div", "ccp-status error", "");
    errLine.style.display = "none";
    modal.append(errLine);
    const btns = el("div", "ccp-form-foot");
    const cancel = el("button", "sw-pill-btn", t("ccxCancel"));
    cancel.addEventListener("click", () => overlay.remove());
    const imp = el("button", "sw-pill-btn ccp-primary", t("ccxImport"));
    imp.addEventListener("click", () => {
      try {
        importProfileJson(profile, ta.value);
        void persist();
        overlay.remove();
        statusMsg = { text: t("ccxImported"), isError: false };
        renderAll();
      } catch (err) {
        errLine.textContent = String(err instanceof Error ? err.message : err);
        errLine.style.display = "";
      }
    });
    btns.append(cancel, imp);
    modal.append(btns);
    overlay.append(modal);
    overlay.addEventListener("click", (ev) => { if (ev.target === overlay) overlay.remove(); });
    detail.append(overlay);
  };

  /** Map a pasted settings.json (or bare env block) into the profile —
   * macOS `ClaudeCodeConfigWriter.importProfile(fromJSON:)`. */
  const importProfileJson = (profile: ClaudeCodeProfile, text: string) => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error(t("ccxJsonInvalid"));
    }
    if (typeof parsed !== "object" || parsed === null) throw new Error(t("ccxJsonInvalid"));
    const obj = parsed as Record<string, unknown>;
    const isEnvBlock = (v: unknown): v is Record<string, unknown> =>
      typeof v === "object" && v !== null
      && ("ANTHROPIC_BASE_URL" in v || "ANTHROPIC_AUTH_TOKEN" in v || "ANTHROPIC_API_KEY" in v);
    const env = isEnvBlock(obj.env) ? obj.env : isEnvBlock(obj) ? obj : null;
    if (!env) throw new Error(t("ccxJsonNoEnv"));
    const str = (v: unknown): string | null =>
      typeof v === "string" ? clean(v) : typeof v === "number" || typeof v === "boolean" ? String(v) : null;

    const consumed = new Set([
      "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
    ]);
    // Prefer API_KEY (sets the env-key kind) over AUTH_TOKEN — macOS order.
    if (str(env.ANTHROPIC_API_KEY)) {
      profile.token = str(env.ANTHROPIC_API_KEY);
      profile.tokenEnvKey = "ANTHROPIC_API_KEY";
    } else if (str(env.ANTHROPIC_AUTH_TOKEN)) {
      profile.token = str(env.ANTHROPIC_AUTH_TOKEN);
      profile.tokenEnvKey = "ANTHROPIC_AUTH_TOKEN";
    }
    if (str(env.ANTHROPIC_BASE_URL)) profile.baseURL = str(env.ANTHROPIC_BASE_URL);
    profile.haikuModel = str(env.ANTHROPIC_DEFAULT_HAIKU_MODEL) ?? profile.haikuModel;
    profile.sonnetModel = str(env.ANTHROPIC_DEFAULT_SONNET_MODEL) ?? profile.sonnetModel;
    profile.opusModel = str(env.ANTHROPIC_DEFAULT_OPUS_MODEL) ?? profile.opusModel;
    if (env !== obj && str(obj.apiKeyHelper)) profile.apiKeyHelper = str(obj.apiKeyHelper);
    // Remaining env keys → extraEnv, sorted (numbers/bools stringified).
    profile.extraEnv = Object.keys(env)
      .filter((k) => !consumed.has(k) && str(env[k]) !== null)
      .sort()
      .map((k) => ({ id: crypto.randomUUID(), key: k, value: str(env[k])! }));
    // Imported JSON is always Anthropic + direct (macOS ClaudeCodeConfigWriter).
    profile.compatibilityMode = "anthropic";
    profile.openAIFormat = null;
    profile.embeddedLocalProxy = null;
    profile.cliProxyBaseURL = null;
    profile.cliProxyAPIKey = null;
    profile.cliProxyManagementKey = null;
    profile.cliProxyAppliedSignature = null;
  };

  // --- Codex agent sections (macOS codexAgentSections) -----------------------
  const persistCodex = () => {
    if (!workingCodex) return;
    const idx = codexProfiles.findIndex((p) => p.id === workingCodex!.id);
    if (idx >= 0) codexProfiles[idx] = { ...workingCodex };
    else codexProfiles.push({ ...workingCodex });
    settings.codexProfiles = codexProfiles;
    persistDebounced();
  };

  const codexModelCard = (profile: CodexProfile, header?: string): HTMLElement => {
    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("claudeCode.model")));
    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");

    const row = el("div", "ccp-field-row");
    row.append(el("span", "ccp-form-label", t("codexConfig.model")));
    const trail = el("div", "ccp-field-control ccp-model-trail");
    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = "gpt-5.6";
    input.value = profile.model ?? "";
    input.className = "ccp-input ccp-mono";
    input.addEventListener("input", () => {
      profile.model = input.value;
      workingCodex = { ...profile };
      persistCodex();
    });
    trail.append(input);

    const refresh = el("button", "sw-icon-btn", codexModelsLoading ? "…" : "↻") as HTMLButtonElement;
    refresh.title = t(codexModels.length ? "ccxReloadModels" : "ccxLoadModels");
    refresh.disabled = codexModelsLoading || !(clean(profile.baseURL) && clean(profile.apiKey));
    refresh.addEventListener("click", async () => {
      if (!clean(profile.baseURL) || !clean(profile.apiKey)) return;
      codexModelsLoading = true;
      renderDetail();
      try {
        const fetched = await invoke<string[]>("claude_code_models", {
          baseUrl: profile.baseURL,
          token: profile.apiKey,
        });
        codexModels = fetched;
      } catch (err) {
        statusMsg = { text: String(err), isError: true };
      }
      codexModelsLoading = false;
      renderDetail();
    });
    trail.append(refresh);

    const options = [...codexModels];
    if (clean(profile.model) && !options.includes(profile.model)) options.unshift(profile.model);
    if (options.length > 0) {
      const sel = document.createElement("select");
      sel.className = "ccp-input ccp-select ccp-mono ccp-model-pick";
      const blank = document.createElement("option");
      blank.value = "";
      blank.textContent = "…";
      sel.append(blank);
      for (const m of options) {
        const o = document.createElement("option");
        o.value = m;
        o.textContent = m;
        if (m === profile.model) o.selected = true;
        sel.append(o);
      }
      sel.addEventListener("change", () => {
        if (!sel.value) return;
        profile.model = sel.value;
        workingCodex = { ...profile };
        persistCodex();
        renderDetail();
      });
      trail.append(sel);
    }
    row.append(trail);
    body.append(row);

    // Connection only when protocol allows direct (OpenAI Responses).
    if (!codexRequiresProxy(profile)) {
      body.append(el("div", "ccp-row-divider"));
      const connRow = el("div", "ccp-field-row");
      connRow.append(el("span", "ccp-form-label", t("codexConfig.connection")));
      const connSeg = el("div", "ccp-seg");
      const mkConn = (mode: "direct" | "local-proxy", label: string) => {
        const active = (mode === "local-proxy") === codexUsesProxy(profile);
        const btn = el("button", `ccp-seg-btn${active ? " active" : ""}`, label) as HTMLButtonElement;
        btn.type = "button";
        btn.addEventListener("click", () => {
          profile.connectionModeRaw = mode;
          profile.cliProxyAppliedSignature = null;
          workingCodex = { ...profile };
          persistCodex();
          renderDetail();
        });
        return btn;
      };
      connSeg.append(mkConn("direct", t("codexConfig.connection.direct")));
      connSeg.append(mkConn("local-proxy", t("codexConfig.connection.proxy")));
      const ctrail = el("div", "ccp-field-control");
      ctrail.append(connSeg);
      connRow.append(ctrail);
      body.append(connRow);
    }

    card.append(body);
    group.append(card);
    return group;
  };

  const codexProxyCard = async (profile: CodexProfile, header?: string): Promise<HTMLElement> => {
    // Reuse Claude proxy card styling; fetch Codex-specific status.
    let st: ProxyStatus | null = null;
    try {
      st = await invoke<ProxyStatus>("cli_proxy_codex_status", { profileId: profile.id });
    } catch {
      st = {
        state: "stopped",
        endpoint: PROXY_ENDPOINT,
        configurationCurrent: false,
        hasUpstream: codexHasUpstream(profile),
      };
    }
    // Build a pseudo-Claude profile so proxyStatusCard UI is reused... but that
    // card is Claude-only. Render a compact Codex proxy card instead.
    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("ccx.step.proxy")));
    const card = el("div", "sw-card");
    const head = el("div", "ccp-proxy-head");
    const stateKey = st?.state ?? "stopped";
    const title = t(
      stateKey === "running" ? "ccxProxyStatusRunning"
        : stateKey === "needsUpdate" ? "ccxProxyStatusNeedsUpdate"
          : stateKey === "starting" ? "ccxProxyStatusStarting"
            : stateKey === "failed" ? "ccxProxyStatusFailed"
              : "ccxProxyStatusStopped",
    );
    head.append(el("div", "ccp-proxy-title", title));
    head.append(el(
      "div",
      "ccp-proxy-detail",
      stateKey === "running" || stateKey === "needsUpdate"
        ? t("codexConfig.proxy.running")
        : t("codexConfig.proxy.stopped"),
    ));
    const actions = el("div", "ccp-proxy-actions");
    if (stateKey === "running" && st?.configurationCurrent) {
      const stopBtn = el("button", "sw-pill-btn", t("ccxProxyStop")) as HTMLButtonElement;
      stopBtn.addEventListener("click", async () => {
        const ok = await ask(t("codexConfig.proxy.stopConfirmMessage"), {
          title: t("codexConfig.proxy.stopConfirmTitle"),
          kind: "warning",
        }).catch(() => false);
        if (!ok) return;
        await invoke("cli_proxy_stop");
        proxyFeedback = { text: t("ccxProxyStopDone"), isError: false };
        renderDetail();
      });
      actions.append(stopBtn);
    } else {
      const startBtn = el(
        "button",
        "sw-pill-btn ccp-primary",
        stateKey === "needsUpdate" ? t("ccxProxyUpdate") : t("ccxProxyStart"),
      ) as HTMLButtonElement;
      startBtn.disabled = !codexHasUpstream(profile) || proxyBusy;
      startBtn.addEventListener("click", async () => {
        if (!codexHasUpstream(profile)) {
          statusMsg = { text: t("codexConfig.error.incomplete"), isError: true };
          renderDetail();
          return;
        }
        proxyBusy = true;
        renderDetail();
        try {
          await persist();
          await invoke<ProxyStatus>("cli_proxy_codex_prepare", { profileId: profile.id });
          await reloadCodexFromDisk(profile.id);
          proxyFeedback = { text: t("ccxProxyStarted"), isError: false };
        } catch (err) {
          proxyFeedback = { text: String(err), isError: true };
        }
        proxyBusy = false;
        renderDetail();
      });
      actions.append(startBtn);
    }
    head.append(actions);
    card.append(head);
    card.append(el("div", "ccp-row-divider"));
    const epRow = el("div", "ccp-proxy-endpoint-row");
    epRow.append(el("span", "ccp-proxy-ep-label", t("ccxProxyLocalEndpoint")));
    epRow.append(el("span", "ccp-proxy-ep-value ccp-mono", st?.endpoint ?? PROXY_ENDPOINT));
    card.append(epRow);
    if (proxyFeedback) {
      card.append(el("div", "ccp-row-divider"));
      card.append(el(
        "div",
        `ccp-proxy-feedback${proxyFeedback.isError ? " error" : ""}`,
        proxyFeedback.text,
      ));
    }
    group.append(card);
    return group;
  };

  const codexActivationCard = (
    profile: CodexProfile,
    st: CodexProfileState,
    header?: string,
  ): HTMLElement => {
    const group = el("div", "sw-group");
    group.append(el("div", "sw-section-header", header ?? t("codexConfig.target")));
    const card = el("div", "sw-card ccp-activation");
    const row = el("div", "ccp-act-row");

    const iconBox = el("div", `ccp-act-icon ccp-act-${st.state === "active" ? "on" : st.state === "stale" ? "stale" : st.state === "setup" ? "needsSetup" : "off"}`);
    iconBox.append(settingsIcon("terminal", "ccp-act-svg"));
    row.append(iconBox);

    const body = el("div", "ccp-act-body");
    const titleRow = el("div", "ccp-act-title-row");
    titleRow.append(el("span", "ccp-act-title", t(`codexConfig.state.${st.state === "stale" ? "stale" : st.state === "active" ? "active" : st.state === "setup" ? "setup" : "ready"}`)));
    body.append(titleRow);
    body.append(el("div", "ccp-act-target ccp-mono", st.targetPath || t("codexConfig.target.path")));
    row.append(body);

    const actions = el("div", "ccp-codex-actions");
    if (st.active && st.current) {
      const deact = el("button", "sw-pill-btn ccp-danger", t("codexConfig.deactivate")) as HTMLButtonElement;
      deact.disabled = busy;
      deact.addEventListener("click", async () => {
        if (busy) return;
        busy = true;
        renderDetail();
        try {
          await invoke("codex_deactivate", { id: profile.id });
          await reloadCodexFromDisk(profile.id);
          statusMsg = { text: t("codexConfig.deactivated"), isError: false };
        } catch (err) {
          statusMsg = { text: String(err), isError: true };
        }
        busy = false;
        renderDetail();
      });
      actions.append(deact);
    } else {
      const apply = el(
        "button",
        "sw-pill-btn ccp-primary",
        st.active ? t("codexConfig.update") : t("codexConfig.apply"),
      ) as HTMLButtonElement;
      apply.disabled = busy || !codexHasUpstream(profile);
      apply.addEventListener("click", async () => {
        if (busy || !codexHasUpstream(profile)) {
          if (!codexHasUpstream(profile)) {
            statusMsg = { text: t("codexConfig.error.incomplete"), isError: true };
            renderDetail();
          }
          return;
        }
        busy = true;
        statusMsg = null;
        renderDetail();
        try {
          await persist();
          // Persist working model/connection first via settings.
          if (workingCodex) {
            const idx = codexProfiles.findIndex((p) => p.id === workingCodex!.id);
            if (idx >= 0) codexProfiles[idx] = { ...workingCodex };
            settings.codexProfiles = codexProfiles;
            await persist();
          }
          const next = await invoke<CodexProfileState>("codex_apply", { id: profile.id });
          await reloadCodexFromDisk(profile.id);
          let msg = t(st.active ? "codexConfig.updated" : "codexConfig.applied");
          if (next.profileFlag) {
            msg += " " + t("codexConfig.runWith", { cmd: `codex --profile ${next.profileFlag}` });
          }
          statusMsg = { text: msg, isError: false };
        } catch (err) {
          statusMsg = { text: String(err), isError: true };
        }
        busy = false;
        renderDetail();
      });
      actions.append(apply);
    }
    row.append(actions);
    card.append(row);

    card.append(el("div", "ccp-row-divider"));
    const foot = el("div", "ccp-codex-foot");
    foot.append(el(
      "span",
      "ccp-proxy-detail",
      codexUsesProxy(profile) ? t("codexConfig.connection.proxy") : t("codexConfig.connection.direct"),
    ));
    const del = el("button", "sw-icon-btn ccp-danger") as HTMLButtonElement;
    del.append(settingsIcon("trash", "ccp-trash-icon"));
    del.title = t("codexConfig.delete");
    del.disabled = busy;
    del.addEventListener("click", async () => {
      const isCustom = selected?.kind === "profile";
      const ok = await ask(t("codexConfig.deleteConfirm"), {
        title: t("codexConfig.delete"),
        kind: "warning",
      }).catch(() => false);
      if (!ok) return;
      busy = true;
      try {
        await invoke("codex_delete", {
          id: profile.id,
          deleteLinkedClaude: isCustom,
        });
        if (isCustom && selected && selected.kind === "profile") {
          const deletedClaudeId = selected.profile.id;
          settings.claudeCodeProfiles = profiles.filter((p) => p.id !== deletedClaudeId);
          profiles.length = 0;
          profiles.push(...(settings.claudeCodeProfiles ?? []));
        }
        settings.codexProfiles = codexProfiles.filter((p) => p.id !== profile.id);
        codexProfiles.length = 0;
        codexProfiles.push(...(settings.codexProfiles ?? []));
        // Clear provider link for preset.
        if (selected?.kind === "provider") {
          selected.cfg.codexProfileID = null;
        }
        detailAgent = "claudeCode";
        workingCodex = null;
        statusMsg = null;
        if (isCustom) {
          selected = null;
          const first = eligibleProviders()[0];
          if (first) selectProvider(first);
          else renderAll();
          return;
        }
      } catch (err) {
        statusMsg = { text: String(err), isError: true };
      }
      busy = false;
      renderAll();
    });
    foot.append(del);
    card.append(foot);
    group.append(card);
    return group;
  };

  const codexProjectUseCard = (flag: string): HTMLElement => {
    const command = `codex --profile ${flag}`;
    const group = el("div", "sw-group");
    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");
    const row = el("div", "ccp-field-row");
    const left = el("div", "ccp-act-body");
    left.append(el("div", "ccp-act-title", t("codexConfig.projectUse.title")));
    left.append(el("div", "ccp-act-target ccp-mono", command));
    row.append(left);
    const copy = el("button", "sw-icon-btn", "⎘") as HTMLButtonElement;
    copy.title = t("codexConfig.projectUse.copy");
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(command);
        statusMsg = { text: t("codexConfig.projectUse.copy"), isError: false };
        renderDetail();
      } catch { /* ignore */ }
    });
    row.append(copy);
    body.append(row);
    body.append(el("div", "pp-field-hint ccp-nopad", t("codexConfig.projectUse.hint")));
    card.append(body);
    group.append(card);
    return group;
  };

  const renderCodexSections = async (
    scroll: HTMLElement,
    profile: CodexProfile,
    headers?: {
      modelHeader?: string;
      proxyHeader?: string;
      activateHeader?: string;
      prefetchedState?: CodexProfileState;
    },
  ) => {
    scroll.append(codexModelCard(profile, headers?.modelHeader));
    if (codexUsesProxy(profile)) {
      scroll.append(await codexProxyCard(profile, headers?.proxyHeader));
    }
    let st: CodexProfileState = headers?.prefetchedState ?? {
      state: "setup",
      active: false,
      current: false,
      targetPath: t("codexConfig.target.path"),
      usesProxy: codexUsesProxy(profile),
    };
    if (!headers?.prefetchedState) {
      try {
        st = await invoke<CodexProfileState>("codex_profile_state", { id: profile.id });
      } catch { /* use defaults */ }
    }
    scroll.append(codexActivationCard(profile, st, headers?.activateHeader));
    if (statusMsg) {
      scroll.append(el("div", `ccp-status${statusMsg.isError ? " error" : ""}`, statusMsg.text));
    }
    if (st.profileFlag) {
      scroll.append(codexProjectUseCard(st.profileFlag));
    }
  };

  // --- empty state (macOS remake: 3 steps) ------------------------------------
  const emptyState = (): HTMLElement => {
    const wrap = el("div", "ccp-empty-wrap");
    const card = el("div", "sw-card ccp-empty");
    const icon = el("div", "ccp-empty-icon");
    icon.append(settingsIcon("terminal", "ccp-empty-svg"));
    card.append(icon);
    card.append(el("div", "ccp-empty-title", t("ccxEmptyTitle")));
    card.append(el("div", "ccp-empty-body", t("ccxEmptyBody")));
    const btns = el("div", "ccp-form-foot ccp-center");
    const addCfg = el("button", "sw-pill-btn ccp-primary", t("ccxAddConfig"));
    addCfg.addEventListener("click", () => {
      const profile: ClaudeCodeProfile = {
        id: crypto.randomUUID(), name: t("ccxNewConfig"),
        tokenEnvKey: "ANTHROPIC_AUTH_TOKEN", extraEnv: [],
      };
      profiles.push(profile);
      void persist();
      selectProfile(profile);
    });
    const openProviders = el("button", "sw-pill-btn", t("ccxOpenProviders"));
    openProviders.addEventListener("click", () => {
      window.dispatchEvent(new CustomEvent("birdnion-settings-section", { detail: "providers" }));
    });
    btns.append(addCfg, openProviders);
    card.append(btns);
    const steps = el("div", "ccp-empty-steps");
    ["ccxEmptyStep1", "ccxEmptyStep2", "ccxEmptyStep3"].forEach((key, i) => {
      const row = el("div", "ccp-empty-step");
      row.append(el("span", "ccp-empty-step-num", String(i + 1)));
      row.append(el("span", "ccp-empty-step-label", t(key)));
      steps.append(row);
    });
    card.append(steps);
    wrap.append(card);
    return wrap;
  };

  /** Dynamic step breadcrumb for custom profiles (macOS customStepsBreadcrumb). */
  const customStepsBreadcrumb = (
    profile: ClaudeCodeProfile,
    opts: {
      proxySt: ProxyStatus | null;
      power: ClaudeCodePowerState | null;
      codexSt: CodexProfileState | null;
    },
  ): HTMLElement => {
    const hasProxy = detailAgent === "codex"
      ? (workingCodex ? codexUsesProxy(workingCodex) : usesLocalProxy(profile))
      : usesLocalProxy(profile);
    const upstreamDone = hasUpstream(profile);
    const agentDone = true;
    const modelDone = detailAgent === "codex"
      ? !!clean(workingCodex?.model)
      : !!(clean(profile.haikuModel) || clean(profile.sonnetModel) || clean(profile.opusModel));
    const proxyDone = hasProxy && !!opts.proxySt
      && opts.proxySt.state === "running"
      && opts.proxySt.configurationCurrent;
    const activateDone = detailAgent === "codex"
      ? !!(opts.codexSt && (opts.codexSt.state === "active" || (opts.codexSt.active && opts.codexSt.current)))
      : opts.power === "on";

    type Step = { n: number; key: string; done: boolean };
    const steps: Step[] = [
      { n: 1, key: "ccx.step.upstream", done: upstreamDone },
      { n: 2, key: "aiCoding.step.agent", done: agentDone },
      { n: 3, key: "claudeCode.model", done: modelDone },
    ];
    if (hasProxy) {
      steps.push({ n: 4, key: "ccx.step.proxy", done: proxyDone });
      steps.push({
        n: 5,
        key: detailAgent === "codex" ? "codexConfig.target" : "aiCoding.claudeCode.settings",
        done: activateDone,
      });
    } else {
      steps.push({
        n: 4,
        key: detailAgent === "codex" ? "codexConfig.target" : "aiCoding.claudeCode.settings",
        done: activateDone,
      });
    }

    const bar = el("div", "ccp-breadcrumb");
    steps.forEach((step, idx) => {
      if (idx > 0) bar.append(el("span", "ccp-breadcrumb-sep", "·"));
      const item = el("span", "ccp-breadcrumb-step");
      item.append(el("span", "ccp-breadcrumb-num", `${step.n}.`));
      item.append(el(
        "span",
        "ccp-breadcrumb-label",
        `${t(step.key)}${step.done ? " ✓" : ""}`.toUpperCase(),
      ));
      bar.append(item);
    });
    return bar;
  };

  const withStepHeader = (header: string, child: HTMLElement): HTMLElement => {
    const g = el("div", "sw-group");
    g.append(el("div", "sw-section-header", header));
    // Child may already be .sw-group — unwrap its first card/content.
    if (child.classList.contains("sw-group") || child.classList.contains("ccp-form")) {
      while (child.firstChild) g.append(child.firstChild);
    } else {
      g.append(child);
    }
    return g;
  };

  // --- detail render -----------------------------------------------------------
  const renderDetail = () => {
    detail.textContent = "";
    const scroll = el("div", "pp-detail-scroll");
    if (!selected) {
      scroll.append(emptyState());
      detail.append(scroll);
      return;
    }
    const sel = selected;
    const pickerId = sel.kind === "provider" ? `preset-${sel.cfg.id}` : sel.profile.id;
    const isCustom = sel.kind === "profile";

    // Placeholder panel first, replaced when the disk state resolves.
    void (async () => {
      // Custom Codex path: upstream → agent → model → proxy? → activate
      if (detailAgent === "codex") {
        if (!workingCodex) {
          try {
            if (sel.kind === "profile") {
              workingCodex = await invoke<CodexProfile>("codex_ensure_counterpart", {
                claudeProfileId: sel.profile.id,
              });
            } else {
              workingCodex = await invoke<CodexProfile>("codex_ensure_preset", {
                providerId: sel.cfg.id,
              });
            }
            await reloadCodexFromDisk(workingCodex.id);
          } catch (err) {
            scroll.textContent = "";
            if (isCustom) {
              scroll.append(customStepsBreadcrumb(sel.profile, {
                proxySt: null, power: null, codexSt: null,
              }));
              scroll.append(withStepHeader(
                stepTitle(1, "ccx.step.upstream"),
                profileFormUpstreamOnly(sel.profile),
              ));
            }
            scroll.append(agentPickerCard(pickerId, isCustom ? stepTitle(2, "aiCoding.step.agent") : undefined));
            scroll.append(el("div", "ccp-status error", String(err)));
            return;
          }
        }
        if (selected !== sel) return;

        let codexSt: CodexProfileState | null = null;
        let proxySt: ProxyStatus | null = null;
        try {
          codexSt = await invoke<CodexProfileState>("codex_profile_state", { id: workingCodex!.id });
        } catch { /* defaults */ }
        if (codexUsesProxy(workingCodex!)) {
          try {
            proxySt = await invoke<ProxyStatus>("cli_proxy_codex_status", {
              profileId: workingCodex!.id,
            });
          } catch {
            proxySt = {
              state: "stopped",
              endpoint: PROXY_ENDPOINT,
              configurationCurrent: false,
              hasUpstream: codexHasUpstream(workingCodex!),
            };
          }
        }
        if (selected !== sel) return;

        const hasProxy = codexUsesProxy(workingCodex!);
        const actN = hasProxy ? 5 : 4;
        scroll.textContent = "";
        if (isCustom) {
          scroll.append(customStepsBreadcrumb(sel.profile, {
            proxySt, power: null, codexSt,
          }));
          scroll.append(withStepHeader(
            stepTitle(1, "ccx.step.upstream"),
            profileFormUpstreamOnly(sel.profile),
          ));
        }
        scroll.append(agentPickerCard(
          pickerId,
          isCustom ? stepTitle(2, "aiCoding.step.agent") : undefined,
        ));
        await renderCodexSections(scroll, workingCodex!, {
          modelHeader: isCustom ? stepTitle(3, "claudeCode.model") : undefined,
          proxyHeader: isCustom && hasProxy ? stepTitle(4, "ccx.step.proxy") : undefined,
          activateHeader: isCustom ? stepTitle(actN, "codexConfig.target") : undefined,
          prefetchedState: codexSt ?? undefined,
        });
        return;
      }

      const state = await resolveState(sel);
      if (selected !== sel) return;

      let proxySt: ProxyStatus | null = null;
      if (sel.kind === "profile" && usesLocalProxy(sel.profile)) {
        proxySt = await invoke<ProxyStatus>("cli_proxy_status", {
          profileId: sel.profile.id,
        }).catch(() => ({
          state: "stopped",
          endpoint: PROXY_ENDPOINT,
          configurationCurrent: false,
          hasUpstream: hasUpstream(sel.profile),
        }));
      }
      if (selected !== sel) return;

      scroll.textContent = "";
      if (sel.kind === "provider") {
        scroll.append(agentPickerCard(pickerId));
        scroll.append(activationPanel(sel, state));
        if (statusMsg) scroll.append(el("div", `ccp-status${statusMsg.isError ? " error" : ""}`, statusMsg.text));
        scroll.append(scopeCard(sel));
        scroll.append(modelCard(sel));
        scroll.append(disable1MCard(sel.cfg));
      } else {
        // Custom Claude: breadcrumb → upstream → agent → model → proxy? → activate
        // (macOS claudeAgentSections order).
        const hasProxy = usesLocalProxy(sel.profile);
        const actN = hasProxy ? 5 : 4;
        scroll.append(customStepsBreadcrumb(sel.profile, {
          proxySt, power: state, codexSt: null,
        }));
        scroll.append(withStepHeader(
          stepTitle(1, "ccx.step.upstream"),
          profileFormUpstreamOnly(sel.profile),
        ));
        const pasteRow = el("div", "ccp-paste-row");
        const pasteBtn = el("button", "sw-pill-btn", t("ccxPasteJson"));
        pasteBtn.addEventListener("click", () => openPasteModal(sel.profile));
        pasteRow.append(pasteBtn);
        scroll.append(pasteRow);
        scroll.append(agentPickerCard(pickerId, stepTitle(2, "aiCoding.step.agent")));
        scroll.append(modelCard(sel, stepTitle(3, "claudeCode.model")));
        if (hasProxy) {
          scroll.append(proxyStatusCard(sel.profile, proxySt, stepTitle(4, "ccx.step.proxy")));
        }
        scroll.append(withStepHeader(
          stepTitle(actN, "aiCoding.claudeCode.settings"),
          activationPanel(sel, state),
        ));
        if (statusMsg) scroll.append(el("div", `ccp-status${statusMsg.isError ? " error" : ""}`, statusMsg.text));
        scroll.append(scopeCard(sel));
        scroll.append(profileFormClaudeOnly(sel.profile));
      }
    })();
    detail.append(scroll);
  };

  /** Upstream card only (name + API standard + credentials) — shared by both agents. */
  const profileFormUpstreamOnly = (profile: ClaudeCodeProfile): HTMLElement => {
    // Reuse full form for now but hide Claude-only model/advanced when agent is codex
    // via a flag on the form builder.
    return profileForm(profile, { upstreamOnly: true });
  };

  /** Claude-only sections after agent picker (models + advanced + delete). */
  const profileFormClaudeOnly = (profile: ClaudeCodeProfile): HTMLElement => {
    return profileForm(profile, { claudeOnly: true });
  };

  const renderAll = () => {
    renderSidebar();
    renderDetail();
  };

  // Seed model suggestions per preset provider (saved values + suggested).
  const seedModels = async (cfg: ProviderCfg) => {
    const key = `p:${cfg.id}`;
    if (modelCache.has(key)) return;
    const info = await invoke<{ suggestedModels: string[] }>("claude_code_backend_info", { providerId: cfg.id }).catch(() => null);
    modelCache.set(key, orderedUnique([
      cfg.claudeHaikuModel, cfg.claudeSonnetModel, cfg.claudeOpusModel,
      ...(info?.suggestedModels ?? []),
    ]));
    if (selected?.kind === "provider" && selected.cfg.id === cfg.id) renderDetail();
  };

  // Initial selection: first eligible provider (macOS default).
  const first = eligibleProviders()[0];
  if (first) {
    selected = { kind: "provider", cfg: first };
    void seedModels(first);
  }
  renderAll();

  return root;
}
