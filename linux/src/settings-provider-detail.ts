// Settings → Providers detail column — port of the macOS ProvidersPane
// right-hand column: info grid (status/source/plan/version/service/storage),
// usage section (pace + reserve lines, credits, local cost rows), setup
// fields, per-provider quota-warning thresholds, and the links list.

import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { t, currentLang } from "./i18n";
import type { ProviderStatus, QuotaWindow } from "./provider-tab";
import type { UsageReport } from "./usage";
import { tokensShort } from "./usage";
import {
  isHidePersonalInfo, isProviderStorageEnabled,
  getProviderQuotaWarn, setProviderQuotaWarn, getQuotaWarnL1, getQuotaWarnL2,
} from "./settings-about";
import { trayVisibilityToggle, regionSelect, claudeSourceSelect } from "./settings-provider-row";
import { claudeCodeSettingsSection } from "./claude-code-settings";
import { copilotDeviceLoginRow } from "./settings-copilot-login";
import { codexAccountsSection } from "./settings-codex-accounts";
import { freemodelAccountsSection } from "./settings-freemodel-accounts";
import { elevenlabsKeysSection } from "./settings-elevenlabs-keys";

/** settings.json provider entry (shared schema with macOS). */
export type ProviderCfg = {
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
  source?: string | null;
};

export type Settings = { version: number; providers: ProviderCfg[] };

/** Providers whose auth is a pasted API key. */
export const KEYED = new Set([
  "minimax", "hapo", "openrouter", "deepseek", "zai", "elevenlabs",
  "deepgram", "groq", "kiro", "kilo", "alibaba", "bedrock", "openai", "ollama",
]);
/** Providers that can use browser cookies. */
export const COOKIED = new Set([
  "opencode", "opencodego", "commandcode", "cursor", "mimo",
  "alibaba", "freemodel", "copilot", "ollama",
]);
/** Providers with a local data dir the storage scanner knows about. */
const STORAGE_IDS = new Set([
  "claude", "codex", "grok", "gemini", "copilot", "opencode", "opencodego", "cursor",
]);

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// --- time/pace helpers (macOS WindowPace / L10n.relativeUpdated) -----------

/** "vừa cập nhật" / "{n} phút trước" — macOS relativeUpdated. */
export function relativeUpdated(ts: number | null | undefined): string | null {
  if (ts == null || !Number.isFinite(ts) || ts <= 0) return null;
  const ms = ts > 1e12 ? ts : ts * 1000;
  const secs = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (secs < 5) return t("provider.justUpdated");
  if (secs < 60) return t("provider.secondsAgo", { n: secs });
  if (secs < 3600) return t("provider.minutesAgo", { n: Math.round(secs / 60) });
  if (secs < 86400) return t("provider.hoursAgo", { n: Math.round(secs / 3600) });
  const d = new Date(ms);
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** "Xd Yh" / "Xh Ym" / "Xm" — macOS WindowPace.format. */
function formatCountdown(totalSeconds: number): string {
  const mins = Math.max(0, Math.round(totalSeconds / 60));
  const days = Math.floor(mins / 1440);
  const hours = Math.floor((mins % 1440) / 60);
  const rem = mins % 60;
  if (days >= 1) return `${days}d ${hours}h`;
  if (hours >= 1) return `${hours}h ${rem}m`;
  return `${rem}m`;
}

type WindowPace = { reservePct: number; lastsUntilReset: boolean; resetIn: string };

/** Pace/reserve math — direct port of macOS `WindowPace(window:)`
 * (ProviderStatus.swift): needs both resetsAt and windowSeconds. */
function windowPace(w: QuotaWindow): WindowPace | null {
  if (!w.resetsAt || !w.windowSeconds || w.windowSeconds <= 0) return null;
  const now = Date.now() / 1000;
  const duration = w.windowSeconds;
  const untilReset = Math.max(0, w.resetsAt - now);
  const resetIn = formatCountdown(untilReset);
  const elapsed = Math.min(Math.max(duration - untilReset, 0), duration);
  if (elapsed <= 0) return { reservePct: 0, lastsUntilReset: true, resetIn };
  const expectedUsed = (elapsed / duration) * 100;
  const reservePct = Math.max(0, Math.round(expectedUsed - w.usedPct));
  const projectedAtReset = w.usedPct * (duration / elapsed);
  return { reservePct, lastsUntilReset: projectedAtReset <= 100, resetIn };
}

// --- info grid --------------------------------------------------------------

function infoRow(label: string, value: string | HTMLElement, title?: string): HTMLElement {
  const row = el("div", "pp-info-row");
  row.append(el("span", "pp-info-label", label));
  if (typeof value === "string") {
    const v = el("span", "pp-info-value", value);
    if (title) v.title = title;
    row.append(v);
  } else {
    row.append(value);
  }
  return row;
}

/** Translated self-test-disabled sentinel, else the raw error. */
export function displayError(error: string): string {
  return error === "provider.selfTest.disabled" ? t(error) : error;
}

/** macOS detailInfoGrid: Status / Source / Plan / Plan name / Account /
 * Version / Service status / Error-or-Updated / Storage. */
export function detailInfoGrid(id: string, enabled: boolean, st: ProviderStatus | undefined): HTMLElement {
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");

  body.append(infoRow(t("provider.status"), enabled ? t("popoverReady") : t("provider.disabled")));
  if (st?.sourceLabel) body.append(infoRow(t("provider.source"), st.sourceLabel));
  if (st?.planType) {
    body.append(infoRow(t("provider.plan"), st.planType.charAt(0).toUpperCase() + st.planType.slice(1)));
  }
  if (st?.planName) body.append(infoRow(t("provider.planName"), st.planName));
  const account = isHidePersonalInfo() ? null : (st?.accountLabel || st?.signedInEmail);
  if (account) body.append(infoRow(t("provider.account"), account));
  if (st?.version) body.append(infoRow(t("provider.version"), st.version));
  if (id === "kiro" && st?.kiroContextPercent != null) {
    // Context-window usage from `kiro-cli /context` (best-effort).
    body.append(infoRow(t("provider.kiroContext"), `${Math.round(st.kiroContextPercent)}%`));
  }

  if (st?.serviceStatus) {
    const value = el("span", "pp-info-value pp-svc");
    value.append(el("span", `pp-svc-dot ${st.serviceStatusLevel ?? "unknown"}`));
    const text = st.serviceStatus === "All Systems Operational"
      ? t("provider.allOperational")
      : st.serviceStatus;
    value.append(el("span", "", text));
    body.append(infoRow(t("provider.serviceStatus"), value));
  }

  if (st?.error) {
    // Classified hint like macOS: readable summary, raw error on hover.
    const row = infoRow(t("provider.error"), displayError(st.error), st.error);
    row.classList.add("pp-info-error");
    body.append(row);
    void invoke<string | null>("classify_provider_error", { raw: st.error })
      .then((suffix) => {
        if (!suffix || suffix === "unknown") return;
        const value = row.querySelector(".pp-info-value");
        if (value) value.textContent = t(`providerError.${suffix}.hint`);
      })
      .catch(() => {});
  } else {
    const updated = relativeUpdated(st?.lastUpdated);
    if (updated) body.append(infoRow(t("provider.updated"), updated));
  }

  if (isProviderStorageEnabled() && STORAGE_IDS.has(id)) {
    const row = infoRow(t("provider.storage"), "…");
    body.append(row);
    void invoke<number>("provider_storage", { id })
      .then(async (bytes) => {
        const value = row.querySelector(".pp-info-value");
        if (!value) return;
        value.textContent = bytes > 0
          ? await invoke<string>("format_storage_bytes", { bytes })
          : t("provider.storageNone");
      })
      .catch(() => {});
  }

  card.append(body);
  return card;
}

// --- usage section ----------------------------------------------------------

function usageWindowBlock(providerId: string, w: QuotaWindow): HTMLElement {
  const block = el("div", "pp-usage-block");
  const top = el("div", "pp-usage-top");
  top.append(el("span", "pp-usage-label", w.label.toUpperCase()));
  const pct = el("span", "pp-usage-pct", `${w.remainingPct}%`);
  if (w.remainingPct <= 20) pct.classList.add("critical");
  else if (w.remainingPct <= 50) pct.classList.add("warning");
  top.append(pct);
  const track = el("div", "pp-usage-track");
  const fill = el("div", "pp-usage-fill");
  fill.style.width = `${Math.max(0, Math.min(100, w.remainingPct))}%`;
  if (w.remainingPct <= 20) fill.classList.add("critical");
  else if (w.remainingPct <= 50) fill.classList.add("warning");
  track.append(fill);
  block.append(top, track);

  // Pace foot line — reserve % (weekly only) left, reset countdown right.
  const pace = windowPace(w);
  const isWeek = w.label.includes("Tuần");
  if (pace) {
    const foot = el("div", "pp-usage-foot");
    const left = el("span", "pp-usage-foot-left");
    if (isWeek && pace.reservePct > 0) left.textContent = t("provider.reserve", { n: pace.reservePct });
    foot.append(left);
    foot.append(el("span", "pp-usage-foot-right", t("provider.resetAfter", { t: pace.resetIn })));
    block.append(foot);
    if (isWeek) {
      const note = el(
        "div",
        `pp-usage-note${pace.lastsUntilReset ? "" : " warn"}`,
        pace.lastsUntilReset ? t("provider.enoughUntilReset") : t("provider.mayRunOut"),
      );
      block.append(note);
    }
  } else if (w.resetsAt) {
    const foot = el("div", "pp-usage-foot");
    foot.append(el("span", "pp-usage-foot-left"));
    const secs = Math.max(0, w.resetsAt - Date.now() / 1000);
    foot.append(el("span", "pp-usage-foot-right", t("provider.resetAfter", { t: formatCountdown(secs) })));
    block.append(foot);
  }
  if (w.subtitle) block.append(el("div", "pp-usage-sub", w.subtitle));
  void providerId;
  return block;
}

/** Uppercase key/value row inside the usage card (CREDITS / HÔM NAY / 30 NGÀY). */
function usageKvRow(label: string, value: string): HTMLElement {
  const row = el("div", "pp-usage-kv");
  row.append(el("span", "pp-usage-label", label.toUpperCase()));
  row.append(el("span", "pp-usage-kv-value", value));
  return row;
}

/** Credits value string — macOS: "∞ Unlimited" / "Hết" / "N còn lại". */
function creditsValue(st: ProviderStatus): string | null {
  if (st.creditsUnlimited) return t("provider.creditsUnlimited");
  if (st.creditsRemaining === undefined) return null;
  if (st.creditsRemaining <= 0) return t("provider.outOfCredits");
  const n = Number.isInteger(st.creditsRemaining)
    ? String(st.creditsRemaining)
    : st.creditsRemaining.toFixed(2);
  return t("provider.creditsLeft", { n });
}

/** macOS usageSection: quota windows + credits + local cost rows. */
export function usageSection(id: string, enabled: boolean, st: ProviderStatus | undefined): HTMLElement {
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("settingsSectionUsage")));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");

  if (st && st.windows.length > 0) {
    for (const w of st.windows) body.append(usageWindowBlock(id, w));
  } else {
    body.append(el("div", "pp-usage-empty", enabled ? t("provider.noData") : t("provider.disabledNoData")));
  }

  if (st) {
    const credits = creditsValue(st);
    if (credits) body.append(usageKvRow("Credits", credits));
  }

  // Local cost scan rows (codex/claude only — the scanners exist on Linux
  // and are cached Rust-side, so this is cheap to request per selection).
  if (id === "claude" || id === "codex") {
    const todayRow = usageKvRow(t("provider.today"), "…");
    const monthRow = usageKvRow(t("provider.last30"), "…");
    body.append(todayRow, monthRow);
    void invoke<UsageReport | null>(`${id}_usage_report`)
      .then((report) => {
        const set = (row: HTMLElement, usd: number, tokens: number) => {
          const v = row.querySelector(".pp-usage-kv-value");
          if (v) v.textContent = `≈$${usd.toFixed(2)} · ${tokensShort(tokens)}`;
        };
        if (!report) {
          todayRow.remove();
          monthRow.remove();
          return;
        }
        set(todayRow, report.todayUsd, report.todayTokens);
        set(monthRow, report.last30Usd, report.last30Tokens);
      })
      .catch(() => {
        todayRow.remove();
        monthRow.remove();
      });
  }

  card.append(body);
  group.append(card);
  return group;
}

// --- quota warning card (macOS QuotaWarningCard) ----------------------------

function warnRow(providerId: string, windowKey: "session" | "weekly", title: string): HTMLElement {
  const wrap = el("div", "pp-warn-row");
  const head = el("label", "pp-warn-head");
  const check = document.createElement("input");
  check.type = "checkbox";
  const existing = getProviderQuotaWarn(providerId, windowKey);
  check.checked = existing !== null;
  head.append(check, el("span", "pp-warn-title", t("quotaWarnCustomize", { w: title })));
  wrap.append(head);

  const detail = el("div", "pp-warn-detail");
  const renderDetail = () => {
    detail.textContent = "";
    const cfg = getProviderQuotaWarn(providerId, windowKey);
    if (!cfg) {
      detail.append(el("span", "pp-warn-inherit", t("quotaWarnInherit", { a: getQuotaWarnL1(), b: getQuotaWarnL2() })));
      return;
    }
    const stepper = (label: string, value: number, onChange: (n: number) => void) => {
      const field = el("label", "pp-warn-field");
      field.append(el("span", "pp-warn-label", label));
      const input = document.createElement("input");
      input.type = "number";
      input.min = "1";
      input.max = "100";
      input.step = "5";
      input.value = String(value);
      input.className = "settings-input settings-input-narrow";
      input.addEventListener("change", () => {
        const n = Math.min(100, Math.max(1, Math.round(Number(input.value) || 0)));
        input.value = String(n);
        onChange(n);
      });
      field.append(input, el("span", "pp-warn-label", "%"));
      return field;
    };
    detail.append(
      stepper(t("quotaWarnWarn"), cfg.warn, (n) => setProviderQuotaWarn(providerId, windowKey, { ...getProviderQuotaWarn(providerId, windowKey)!, warn: n })),
      stepper(t("quotaWarnCritical"), cfg.critical, (n) => setProviderQuotaWarn(providerId, windowKey, { ...getProviderQuotaWarn(providerId, windowKey)!, critical: n })),
    );
  };
  check.addEventListener("change", () => {
    setProviderQuotaWarn(
      providerId,
      windowKey,
      check.checked ? { warn: getQuotaWarnL1(), critical: getQuotaWarnL2() } : null,
    );
    renderDetail();
  });
  renderDetail();
  wrap.append(detail);
  return wrap;
}

export function quotaWarningCard(providerId: string): HTMLElement {
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("quotaWarnTitle")));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body pp-warn-body");
  body.append(warnRow(providerId, "session", t("quotaWarnSession")));
  body.append(warnRow(providerId, "weekly", t("quotaWarnWeekly")));
  card.append(body);
  group.append(card);
  group.append(el("div", "sw-card-footer-note", t("quotaWarnFooter")));
  return group;
}

// --- links section (macOS linksSection URL table) ---------------------------

type LinkSpec = { key: string; url: string };
const L = (key: string, url: string): LinkSpec => ({ key, url });
const GOOGLE_STATUS = "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history";

const PROVIDER_LINKS: Record<string, LinkSpec[]> = {
  codex: [
    L("link.usage", "https://chatgpt.com/codex/settings/usage"),
    L("link.status", "https://status.openai.com/"),
    L("link.changelog", "https://github.com/openai/codex/releases"),
  ],
  claude: [
    L("link.billing", "https://console.anthropic.com/settings/billing"),
    L("link.usage", "https://claude.ai/settings/usage"),
    L("link.status", "https://status.claude.com/"),
  ],
  minimax: [L("link.dashboard", "https://platform.minimax.io/")],
  openrouter: [
    L("link.billing", "https://openrouter.ai/settings/credits"),
    L("link.apiKeys", "https://openrouter.ai/keys"),
    L("link.status", "https://status.openrouter.ai"),
  ],
  deepseek: [
    L("link.usage", "https://platform.deepseek.com/usage"),
    L("link.status", "https://status.deepseek.com"),
  ],
  zai: [L("link.subscription", "https://z.ai/manage-apikey/coding-plan/personal/my-plan")],
  elevenlabs: [
    L("link.usage", "https://elevenlabs.io/app/developers/usage"),
    L("link.subscription", "https://elevenlabs.io/app/subscription"),
    L("link.status", "https://status.elevenlabs.io"),
  ],
  deepgram: [
    L("link.dashboard", "https://console.deepgram.com/project/"),
    L("link.status", "https://status.deepgram.com"),
  ],
  groq: [
    L("link.dashboard", "https://console.groq.com/dashboard/metrics"),
    L("link.status", "https://status.groq.com"),
  ],
  grok: [
    L("link.usage", "https://grok.com/?_s=usage"),
    L("link.changelog", "https://x.ai/news"),
    L("link.status", "https://status.x.ai"),
  ],
  openai: [
    L("link.usage", "https://platform.openai.com/usage"),
    L("link.dashboard", "https://platform.openai.com/settings/organization/admin-keys"),
    L("link.status", "https://status.openai.com"),
  ],
  ollama: [
    L("link.dashboard", "https://ollama.com/settings"),
    L("link.apiKeys", "https://ollama.com/settings/keys"),
  ],
  copilot: [
    L("link.dashboard", "https://github.com/settings/copilot"),
    L("link.status", "https://www.githubstatus.com/"),
  ],
  kilo: [L("link.dashboard", "https://app.kilo.ai/usage")],
  commandcode: [L("link.dashboard", "https://commandcode.ai/studio")],
  freemodel: [L("link.usage", "https://freemodel.dev/dashboard/usage")],
  mimo: [L("link.dashboard", "https://platform.xiaomimimo.com/#/console/balance")],
  opencode: [L("link.dashboard", "https://opencode.ai")],
  opencodego: [L("link.dashboard", "https://opencode.ai")],
  cursor: [
    L("link.dashboard", "https://cursor.com/dashboard?tab=usage"),
    L("link.status", "https://status.cursor.com"),
  ],
  gemini: [
    L("link.dashboard", "https://gemini.google.com"),
    L("link.status", GOOGLE_STATUS),
    L("link.changelog", "https://github.com/google-gemini/gemini-cli/releases"),
  ],
  kiro: [
    L("link.dashboard", "https://app.kiro.dev/account/usage"),
    L("link.status", "https://health.aws.amazon.com/health/status"),
  ],
  antigravity: [L("link.status", GOOGLE_STATUS)],
  bedrock: [
    L("link.dashboard", "https://console.aws.amazon.com/bedrock"),
    L("link.status", "https://health.aws.amazon.com/health/status"),
  ],
};

export function linksSection(id: string): HTMLElement | null {
  const links = PROVIDER_LINKS[id];
  if (!links || links.length === 0) return null;
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("settingsSectionLinks")));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");
  for (const link of links) {
    const row = el("button", "pp-link-row");
    row.append(el("span", "pp-link-title", t(link.key)));
    row.append(el("span", "pp-link-arrow", "↗"));
    row.addEventListener("click", () => { void openUrl(link.url); });
    body.append(row);
  }
  card.append(body);
  group.append(card);
  return group;
}

// --- setup section (macOS settingsSection) ----------------------------------

function fieldRow(label: string, control: HTMLElement): HTMLElement {
  const row = el("div", "pp-field-row");
  row.append(el("span", "pp-field-label", label));
  row.append(control);
  return row;
}

function textInput(
  value: string | null | undefined,
  placeholder: string,
  onChange: (v: string | null) => void,
  password = false,
): HTMLInputElement {
  const input = document.createElement("input");
  input.type = password ? "password" : "text";
  input.placeholder = placeholder;
  input.value = value ?? "";
  input.className = "settings-input pp-field-input";
  input.addEventListener("change", () => onChange(input.value.trim() || null));
  return input;
}

/** Cookie source picker (auto/manual/off) + manual cookie field — macOS
 * cookie-provider auth block. */
function cookieControls(cfg: ProviderCfg): HTMLElement {
  const wrap = el("div", "pp-field-stack");
  const select = document.createElement("select");
  select.className = "settings-input pp-select";
  for (const opt of ["auto", "manual", "off"]) {
    const o = document.createElement("option");
    o.value = opt;
    o.textContent = t(`cookieSource.${opt}`);
    select.append(o);
  }
  select.value = cfg.cookieSource ?? "auto";
  const manual = textInput(cfg.manualCookie, t("settingsManualCookie"), (v) => {
    cfg.manualCookie = v;
    if (v) {
      cfg.cookieSource = "manual";
      select.value = "manual";
    }
  }, true);
  manual.style.display = select.value === "manual" ? "" : "none";
  select.addEventListener("change", () => {
    cfg.cookieSource = select.value === "auto" ? null : select.value;
    manual.style.display = select.value === "manual" ? "" : "none";
  });
  wrap.append(fieldRow(t("settingsCookieSource"), select), manual);
  return wrap;
}

/** Bedrock auth block — macOS bedrockAuthSection (keys/profile + region + budget). */
function bedrockAuthSection(cfg: ProviderCfg): HTMLElement {
  const wrap = el("div", "pp-field-stack");
  const mode = document.createElement("select");
  mode.className = "settings-input pp-select";
  for (const opt of ["keys", "profile"]) {
    const o = document.createElement("option");
    o.value = opt;
    o.textContent = t(`bedrockAuth.${opt}`);
    mode.append(o);
  }
  mode.value = cfg.awsAuthMode ?? "keys";
  wrap.append(fieldRow(t("settingsBedrockAuth"), mode));

  const keysStack = el("div", "pp-field-stack");
  keysStack.append(textInput(cfg.apiKey, "Access key ID (AKIA…)", (v) => { cfg.apiKey = v; }, true));
  keysStack.append(textInput(cfg.secretKey, "Secret access key", (v) => { cfg.secretKey = v; }, true));
  const profileStack = el("div", "pp-field-stack");
  profileStack.append(textInput(cfg.awsProfile, "default", (v) => { cfg.awsProfile = v; }));

  const applyMode = () => {
    keysStack.style.display = mode.value === "keys" ? "" : "none";
    profileStack.style.display = mode.value === "profile" ? "" : "none";
  };
  mode.addEventListener("change", () => {
    cfg.awsAuthMode = mode.value === "keys" ? null : mode.value;
    applyMode();
  });
  applyMode();
  wrap.append(keysStack, profileStack);

  wrap.append(textInput(cfg.region, t("settingsBedrockRegion"), (v) => { cfg.region = v; }));
  const budget = textInput(cfg.budget != null ? String(cfg.budget) : "", t("settingsBedrockBudget"), (v) => {
    const n = v === null ? NaN : Number(v);
    cfg.budget = Number.isFinite(n) && n > 0 ? n : null;
  });
  budget.type = "number";
  wrap.append(fieldRow(t("settingsBedrockBudget"), budget));
  return wrap;
}

/** Per-provider refresh cadence select — macOS "Làm mới mỗi" options.
 * Stored in settings.json `refreshInterval` (seconds; null = global). */
function refreshEverySelect(cfg: ProviderCfg): HTMLElement {
  const vi = currentLang() === "vi";
  const OPTIONS: { value: number; vi: string; en: string }[] = [
    { value: 0, vi: t("settingsRefreshDefault"), en: t("settingsRefreshDefault") },
    { value: 30, vi: "30 giây", en: "30 seconds" },
    { value: 60, vi: "1 phút", en: "1 minute" },
    { value: 120, vi: "2 phút", en: "2 minutes" },
    { value: 300, vi: "5 phút", en: "5 minutes" },
    { value: 600, vi: "10 phút", en: "10 minutes" },
    { value: 1800, vi: "30 phút", en: "30 minutes" },
  ];
  const select = document.createElement("select");
  select.className = "settings-input pp-select";
  for (const opt of OPTIONS) {
    const o = document.createElement("option");
    o.value = String(opt.value);
    o.textContent = vi ? opt.vi : opt.en;
    select.append(o);
  }
  const current = cfg.refreshInterval ?? 0;
  select.value = OPTIONS.some((o) => o.value === current) ? String(current) : "0";
  select.addEventListener("change", () => {
    const n = Number(select.value);
    cfg.refreshInterval = n > 0 ? n : null;
  });
  return fieldRow(t("settingsRefreshEvery"), select);
}

/** macOS settingsSection ("THIẾT LẬP"): account label + auth block +
 * per-provider extras + refresh cadence + tray toggle. */
export function setupSection(cfg: ProviderCfg, vi: boolean): HTMLElement {
  const id = cfg.id;
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("settingsSectionSetup")));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body pp-setup-body");

  // 1. Account label (every provider).
  body.append(fieldRow(
    t("settingsAccountLabel"),
    textInput(cfg.accountLabel, t("settingsAccountLabelPlaceholder"), (v) => { cfg.accountLabel = v; }),
  ));

  // 2. Auth block per provider type.
  if (id === "bedrock") {
    body.append(bedrockAuthSection(cfg));
  } else if (KEYED.has(id) && id !== "grok" && id !== "elevenlabs") {
    // ElevenLabs uses the multi-key card (elevenlabsKeysCard) instead of a
    // single TokenField — keys live in elevenlabs-keys.json.
    body.append(fieldRow(
      t("settingsApiKey"),
      textInput(cfg.apiKey, id === "openai" ? "OPENAI_ADMIN_KEY / API key" : t("settingsApiKey"), (v) => { cfg.apiKey = v; }, true),
    ));
  }
  if (id === "openai" || id === "deepgram") {
    body.append(fieldRow(
      "Project ID",
      textInput(cfg.projectId, id === "openai" ? "proj_… (optional)" : "Project ID (optional)", (v) => { cfg.projectId = v; }),
    ));
  }
  if (id === "claude") {
    body.append(fieldRow(
      t("settingsAdminApiKey"),
      textInput(cfg.adminApiKey, t("settingsAdminApiKey"), (v) => { cfg.adminApiKey = v; }, true),
    ));
    body.append(claudeSourceSelect(cfg));
    body.append(cookieControls(cfg));
  }
  if (COOKIED.has(id)) body.append(cookieControls(cfg));
  if (id === "grok") body.append(el("div", "pp-field-hint", t("hint.grok")));
  if (id === "gemini") body.append(el("div", "pp-field-hint", t("hint.gemini")));
  if (id === "kiro") body.append(el("div", "pp-field-hint", t("hint.kiro")));
  if (id === "codex") body.append(el("div", "pp-field-hint", t("hint.codex")));
  if (id === "copilot") {
    body.append(fieldRow(
      t("settingsGheHost"),
      textInput(cfg.baseUrl, "github.com", (v) => { cfg.baseUrl = v; }),
    ));
    body.append(copilotDeviceLoginRow(vi, (label) => { cfg.accountLabel = label; }));
  }

  // 3. Shared extras.
  const region = regionSelect(cfg);
  if (region) body.append(region);
  body.append(refreshEverySelect(cfg));
  body.append(trayVisibilityToggle(cfg));

  const ccSection = claudeCodeSettingsSection(cfg);
  if (ccSection) body.append(ccSection);

  card.append(body);
  group.append(card);
  return group;
}

/** Standalone Codex accounts card — macOS `CodexAccountsCard` sits as its
 * own card AFTER the setup section, not inside it. */
export function codexAccountsCard(): HTMLElement {
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("codexAccountsLabel").toUpperCase()));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");
  body.append(codexAccountsSection());
  card.append(body);
  group.append(card);
  return group;
}

/** Standalone FreeModel accounts card — same shape as the Codex one:
 * "browser" scan + managed pasted-cookie accounts with switch/remove/add. */
export function freemodelAccountsCard(): HTMLElement {
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("fmAccountsLabel").toUpperCase()));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");
  body.append(freemodelAccountsSection());
  card.append(body);
  group.append(card);
  return group;
}

/** Standalone ElevenLabs multi-key card — add / switch / remove API keys. */
export function elevenlabsKeysCard(): HTMLElement {
  const group = el("div", "sw-group");
  group.append(el("div", "sw-section-header", t("elKeysLabel").toUpperCase()));
  const card = el("div", "sw-card");
  const body = el("div", "sw-card-body");
  body.append(elevenlabsKeysSection());
  card.append(body);
  group.append(card);
  return group;
}
