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
};
type CCSettings = Settings & { claudeCodeProfiles?: ClaudeCodeProfile[] };

type Selection = { kind: "provider"; cfg: ProviderCfg } | { kind: "profile"; profile: ClaudeCodeProfile };

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

/** Profile is applyable — macOS `isReady`. */
function profileReady(p: ClaudeCodeProfile): boolean {
  return !!(clean(p.baseURL) && clean(p.token));
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

export async function claudeCodePane(onSaved: () => void): Promise<HTMLElement> {
  void onSaved; // pane persists itself (macOS parity) — no Save button here.
  const vi = currentLang() === "vi";
  void vi;
  const settings = await invoke<CCSettings>("get_settings")
    .catch(() => ({ version: 1, providers: [] as ProviderCfg[] }) as CCSettings);
  settings.claudeCodeProfiles ??= [];
  const profiles = settings.claudeCodeProfiles;

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
  const modelCache = new Map<string, string[]>();
  let modelsLoading = false;
  let statusMsg: { text: string; isError: boolean } | null = null;
  let busy = false;

  const selKey = () => (selected?.kind === "provider" ? `p:${selected.cfg.id}` : `c:${selected?.profile.id}`);

  const root = el("div", "pp-root ccp-root");
  const sidebar = el("div", "pp-sidebar");
  const detail = el("div", "pp-detail");
  root.append(sidebar, detail);

  const selectProvider = (cfg: ProviderCfg) => {
    selected = { kind: "provider", cfg };
    statusMsg = null;
    void seedModels(cfg);
    renderAll();
  };
  const selectProfile = (profile: ClaudeCodeProfile) => {
    selected = { kind: "profile", profile };
    statusMsg = null;
    renderAll();
  };

  // --- sidebar ------------------------------------------------------------
  const renderSidebar = () => {
    sidebar.textContent = "";
    sidebar.append(el("div", "ccp-hint", t("ccxSelectProvider")));

    const list = el("div", "pp-sidebar-list");
    for (const cfg of eligibleProviders()) {
      const row = el("div", `pp-side-row${selected?.kind === "provider" && selected.cfg.id === cfg.id ? " selected" : ""}`);
      row.append(logoMark(cfg.id, "pp-side-logo tab-logo-mono pp-logo-on"));
      const name = el("div", "ccp-side-name", cfg.displayName?.trim() || NAME_BY_ID.get(cfg.id) || cfg.id);
      row.append(name);
      if (presetConfigured(cfg)) row.append(el("span", "ccp-check", "✓"));
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
      const row = el("div", `pp-side-row${selected?.kind === "profile" && selected.profile.id === profile.id ? " selected" : ""}`);
      const icon = el("span", "ccp-profile-icon");
      icon.append(settingsIcon("terminal", "ccp-profile-svg"));
      row.append(icon);
      row.append(el("div", "ccp-side-name", clean(profile.name) ?? t("ccxNewConfig")));
      if (profileReady(profile)) row.append(el("span", "ccp-check", "✓"));
      row.addEventListener("click", () => selectProfile(profile));
      plist.append(row);
    }
    sidebar.append(plist);
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
    if (state === "off") return t("ccxSubOff");
    const scope = sel.kind === "provider" ? sel.cfg.claudeCodeScope : sel.profile.claudeCodeScope;
    const path = sel.kind === "provider" ? sel.cfg.claudeCodeProjectPath : sel.profile.claudeCodeProjectPath;
    if (!scopeOk(scope, path)) return t("ccxSubNeedDir");
    return sel.kind === "provider" ? t("ccxSubNeedModels") : t("ccxSubNeedBase");
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
        if (sel.kind === "provider") await invoke("claude_code_apply", { providerId: sel.cfg.id });
        else await invoke("claude_code_profile_apply", { profileId: sel.profile.id });
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
  const modelCard = (sel: Selection): HTMLElement => {
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
    group.append(el("div", "sw-section-header", t("ccxModelSection")));
    const card = el("div", "sw-card");
    const body = el("div", "sw-card-body");

    // Header row: count + load button.
    const head = el("div", "pp-field-row");
    head.append(el("span", "pp-field-hint ccp-nopad",
      modelsLoading ? t("ccxModelsLoading") : t("ccxModelsLoaded", { n: models.length })));
    const loadBtn = el("button", "sw-pill-btn", models.length > 0 ? t("ccxReloadModels") : t("ccxLoadModels"));
    if (modelsLoading) loadBtn.setAttribute("disabled", "true");
    loadBtn.addEventListener("click", async () => {
      const token = sel.kind === "provider" ? clean(sel.cfg.apiKey) : clean(sel.profile.token);
      let base = sel.kind === "profile" ? clean(sel.profile.baseURL) : null;
      if (sel.kind === "provider") {
        const info = await invoke<{ baseUrl: string | null }>("claude_code_backend_info", { providerId: sel.cfg.id }).catch(() => null);
        base = info?.baseUrl ?? null;
      }
      if (!base || !token) return;
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

  // --- custom profile form (macOS ClaudeCodeCustomProfileForm) ---------------
  const profileForm = (profile: ClaudeCodeProfile): HTMLElement => {
    const wrap = el("div", "ccp-form");

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
      });
      return input;
    };

    // Card 1: name / base URL / token / token kind
    const c1 = el("div", "sw-card");
    const b1 = el("div", "sw-card-body");
    b1.append(fieldRow(t("ccxName"), textField(profile.name, t("ccxNamePlaceholder"), (v) => {
      profile.name = v;
      renderSidebar();
    })));
    b1.append(divider());
    b1.append(fieldRow(t("ccxBaseUrl"), textField(profile.baseURL, "https://api.example.com", (v) => {
      profile.baseURL = v;
    }, { mono: true })));
    b1.append(divider());
    const tokenWrap = el("div", "ccp-token-wrap");
    const tokenInput = textField(profile.token, "sk-…", (v) => { profile.token = v; }, { password: true, mono: true });
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
    b1.append(fieldRow(t("ccxToken"), tokenWrap));
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
    c1.append(b1);
    wrap.append(c1);

    // Card 2: MODEL (free-text tiers — macOS CustomProfileForm, no load button)
    const g2 = el("div", "sw-group");
    g2.append(el("div", "sw-section-header", t("ccxModelSection")));
    const c2 = el("div", "sw-card");
    const b2 = el("div", "sw-card-body");
    const modelRow = (label: string, value: string | null | undefined, set: (v: string | null) => void) => {
      const row = fieldRow(label, textField(value, t("ccxModelOptional"), set, { mono: true }));
      return row;
    };
    b2.append(modelRow(t("ccModelHaiku"), profile.haikuModel, (v) => { profile.haikuModel = v; }));
    b2.append(divider());
    b2.append(modelRow(t("ccModelSonnet"), profile.sonnetModel, (v) => { profile.sonnetModel = v; }));
    b2.append(divider());
    b2.append(modelRow(t("ccModelOpus"), profile.opusModel, (v) => { profile.opusModel = v; }));
    c2.append(b2);
    g2.append(c2);
    wrap.append(g2);

    // Card 3: ADVANCED — apiKeyHelper + extra env
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
      settings.claudeCodeProfiles = profiles.filter((p) => p.id !== profile.id);
      profiles.length = 0;
      profiles.push(...settings.claudeCodeProfiles);
      void persist();
      selected = null;
      const first = eligibleProviders()[0];
      if (first) selectProvider(first);
      else renderAll();
    });
    foot.append(delBtn);
    wrap.append(foot);

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
  };

  // --- empty state ------------------------------------------------------------
  const emptyState = (): HTMLElement => {
    const card = el("div", "sw-card ccp-empty");
    const icon = el("div", "ccp-empty-icon");
    icon.append(settingsIcon("terminal", "ccp-empty-svg"));
    card.append(icon);
    card.append(el("div", "ccp-empty-title", t("ccxEmptyTitle")));
    card.append(el("div", "ccp-empty-body", t("ccxEmptyBody")));
    const btns = el("div", "ccp-form-foot ccp-center");
    const openProviders = el("button", "sw-pill-btn ccp-primary", t("ccxOpenProviders"));
    openProviders.addEventListener("click", () => {
      window.dispatchEvent(new CustomEvent("birdnion-settings-section", { detail: "providers" }));
    });
    const addCfg = el("button", "sw-pill-btn", t("ccxAddConfig"));
    addCfg.addEventListener("click", () => {
      const profile: ClaudeCodeProfile = {
        id: crypto.randomUUID(), name: t("ccxNewConfig"),
        tokenEnvKey: "ANTHROPIC_AUTH_TOKEN", extraEnv: [],
      };
      profiles.push(profile);
      void persist();
      selectProfile(profile);
    });
    btns.append(openProviders, addCfg);
    card.append(btns);
    return card;
  };

  // --- detail render -----------------------------------------------------------
  // Layout: pin the activation panel (power button) ABOVE the scroll region.
  // Previously everything lived in .pp-detail-scroll; focusing a lower form
  // input made WebKit focus-reveal scroll the panel out of view (see
  // fix(linux) overflow:clip). Users then only saw "Paste JSON" + the form
  // and thought the power button was missing / old UI.
  const renderDetail = () => {
    detail.textContent = "";
    if (!selected) {
      const scroll = el("div", "pp-detail-scroll");
      scroll.append(emptyState());
      detail.append(scroll);
      return;
    }
    const sel = selected;

    // Sticky top: activation + status (always visible).
    const top = el("div", "ccp-detail-top");
    // Skeleton while resolveState is in flight (keeps layout stable).
    top.append(activationPanel(sel, "needsSetup"));
    detail.append(top);

    const scroll = el("div", "pp-detail-scroll");
    // Body content is filled once we know power state, so badges match disk.
    void resolveState(sel).then((state) => {
      if (selected !== sel) return;
      top.replaceChildren();
      top.append(activationPanel(sel, state));
      if (statusMsg) {
        top.append(el("div", `ccp-status${statusMsg.isError ? " error" : ""}`, statusMsg.text));
      }

      scroll.textContent = "";
      scroll.append(scopeCard(sel));
      if (sel.kind === "provider") {
        // Preset: scope → models (with load) → 1M toggle (macOS presetDetail).
        scroll.append(modelCard(sel));
        scroll.append(disable1MCard(sel.cfg));
      } else {
        // Custom profile: form owns name/token + MODEL free-text + advanced
        // (macOS ClaudeCodeCustomProfileForm order — no separate load models).
        const pasteRow = el("div", "ccp-paste-row");
        const pasteBtn = el("button", "sw-pill-btn", t("ccxPasteJson"));
        pasteBtn.addEventListener("click", () => openPasteModal(sel.profile));
        pasteRow.append(pasteBtn);
        scroll.append(pasteRow);
        scroll.append(profileForm(sel.profile));
      }
      // Reset scroll so re-selecting a profile never leaves the body mid-page.
      scroll.scrollTop = 0;
    });
    detail.append(scroll);
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
