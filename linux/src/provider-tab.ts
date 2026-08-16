// Per-provider quota view — port of the macOS ProviderCard: quota windows
// with remaining-% bars, error banner, account metadata line, and the
// menu-bar visibility toggle (macOS `MenuBarVisibilityToggle`).

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { currentLang, t } from "./i18n";
import { claudeCodeCard, shouldShowClaudeCode } from "./claude-code";
import {
  isProviderStorageEnabled,
  isHidePersonalInfo,
  isStatusChecksEnabled,
} from "./settings-about";
import { logoMark } from "./logos";

/** Same name as `PROVIDERS_CHANGED_EVENT` in settings-tab (avoid circular import). */
const PROVIDERS_CHANGED_EVENT = "birdnion-providers-changed";

export type QuotaWindow = {
  label: string;
  usedPct: number;
  remainingPct: number;
  subtitle?: string;
  resetsAt?: number;
  /** Window length in seconds (5h/tuần) — drives the settings pace line. */
  windowSeconds?: number;
};

export type ProviderStatus = {
  id: string;
  displayName: string;
  windows: QuotaWindow[];
  lastUpdated: number;
  error?: string;
  accountLabel?: string;
  creditsRemaining?: number;
  /** Codex web-dashboard extras (best-effort cookie enrichment) — port of
   * macOS `CodexWebExtras`. `codeReviewRemainingPercent` is never populated
   * on Linux (see provider backend docs). */
  signedInEmail?: string;
  codeReviewRemainingPercent?: number;
  creditsPurchaseUrl?: string;
  creditsHistoryCount?: number;
  /** Settings detail-grid extras — macOS ProviderStatus parity. */
  planType?: string;
  planName?: string;
  version?: string;
  serviceStatus?: string;
  serviceStatusLevel?: string;
  sourceLabel?: string;
  creditsUnlimited?: boolean;
  /** Kiro context-window usage % from `kiro-cli /context` (best-effort). */
  kiroContextPercent?: number;
  /** JS-side only (never set by Rust): placeholder while the first fetch for
   * this provider is still in flight — renders the loading skeleton instead
   * of "no quota data", mirroring macOS `displayStatuses` placeholders. */
  pending?: boolean;
};

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/**
 * macOS `L10n.relativeUpdated` — "vừa cập nhật" / "N phút trước", not clock time.
 * Accepts unix seconds or ms.
 */
function relativeUpdated(ts: number | null | undefined): string | null {
  if (ts == null || !Number.isFinite(ts) || ts <= 0) return null;
  const ms = ts > 1e12 ? ts : ts * 1000;
  if (Number.isNaN(new Date(ms).getTime())) return null;
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (seconds < 5) return t("time.justUpdated");
  if (seconds < 60) return t("time.secondsAgo", { n: seconds });
  if (seconds < 3600) return t("time.minutesAgo", { n: Math.floor(seconds / 60) });
  return t("time.hoursAgo", { n: Math.floor(seconds / 3600) });
}

export function quotaTone(remaining: number): "ok" | "warning" | "critical" {
  if (remaining <= 20) return "critical";
  if (remaining <= 50) return "warning";
  return "ok";
}

function planLabel(status: ProviderStatus): string | null {
  if (status.planName?.trim()) return status.planName.trim();
  if (status.planType?.trim()) {
    const p = status.planType.trim();
    return p.charAt(0).toUpperCase() + p.slice(1);
  }
  if (status.id === "minimax") return "Token Plan";
  if (status.id === "hapo") return "Hapo AI Hub";
  return null;
}

/** Bonus-credit window labels (FreeModel referral balance, Kiro bonus
 * credits) — expected to sit at 0% once spent, unlike a recurring
 * rate-limit window, so they must not outrank a healthy primary quota as
 * the "lowest" summary (popover strip, tray tooltip, Settings badge).
 * Mirrors macOS `QuotaWindow.isSupplementary`. */
const SUPPLEMENTARY_WINDOW_LABELS = new Set(["Số dư", "Bonus Credits"]);

/** Windows excluding supplementary ones; falls back to all windows when
 * every window is supplementary (never returns an empty set for a status
 * that has data). */
function primaryWindows(windows: QuotaWindow[]): QuotaWindow[] {
  const primary = windows.filter((w) => !SUPPLEMENTARY_WINDOW_LABELS.has(w.label));
  return primary.length > 0 ? primary : windows;
}

/** Lowest-remaining window across the status, ignoring supplementary
 * bonus-credit windows — shared by the popover strip, tray tooltip
 * (`main.ts`), and Settings quota badge (`settings-tab.ts`). */
export function lowestWindow(status: ProviderStatus): QuotaWindow | null {
  if (!status.windows.length) return null;
  return primaryWindows(status.windows).reduce((a, b) => (a.remainingPct < b.remainingPct ? a : b));
}

/** Design window row: LABEL · % / bar / used · reset. */
function windowRow(win: QuotaWindow, lastUpdated: number): HTMLElement {
  const row = el("div", "window-row");
  const head = el("div", "window-head");
  head.append(el("span", "window-label", win.label.toUpperCase()));
  head.append(el("span", `window-pct ${quotaTone(win.remainingPct)}`, `${win.remainingPct}%`));
  const track = el("div", "window-track");
  const fill = el("div", `window-fill ${quotaTone(win.remainingPct)}`);
  fill.style.width = `${Math.max(0, Math.min(100, win.remainingPct))}%`;
  track.append(fill);
  row.append(head, track);
  const foot = el("div", "window-foot");
  foot.append(el("span", "window-subtitle",
    (win.subtitle ?? t("usedPct", { n: win.usedPct })).toUpperCase()));
  let resetAt = win.resetsAt && win.resetsAt > 0 ? win.resetsAt * 1000 : 0;
  if (!resetAt && win.windowSeconds && win.windowSeconds > 0 && lastUpdated > 0) {
    const base = lastUpdated > 1e12 ? lastUpdated : lastUpdated * 1000;
    resetAt = base + win.windowSeconds * 1000;
  }
  if (resetAt) {
    const mins = Math.max(0, Math.round((resetAt - Date.now()) / 60000));
    const label = mins >= 1440 ? t("resetInDays", { n: Math.round(mins / 1440) })
      : mins >= 60 ? t("resetInHours", { n: Math.round(mins / 60) })
      : t("resetInMins", { n: mins });
    foot.append(el("span", "window-subtitle", label.toUpperCase()));
  }
  row.append(foot);
  return row;
}

/** Design lowest-quota hero: eyebrow + big % + reset/used stack. */
function quotaSummaryStrip(status: ProviderStatus): HTMLElement {
  const lowest = lowestWindow(status);
  const strip = el("div", "quota-summary");
  const winLabel = (lowest?.label ?? status.displayName).toUpperCase();
  const eyebrow = `${t("popover.lowestQuota").toUpperCase()} · ${winLabel}`;
  strip.append(el("div", "quota-summary-label", eyebrow));
  const row = el("div", "quota-summary-row");
  const pct = lowest?.remainingPct ?? 0;
  row.append(el("div", `quota-summary-pct ${quotaTone(pct)}`, `${pct}%`));
  const right = el("div", "quota-summary-right");
  // Reset estimate when available.
  if (lowest) {
    let resetAt = lowest.resetsAt && lowest.resetsAt > 0 ? lowest.resetsAt * 1000 : 0;
    if (!resetAt && lowest.windowSeconds && lowest.windowSeconds > 0 && status.lastUpdated > 0) {
      const base = status.lastUpdated > 1e12 ? status.lastUpdated : status.lastUpdated * 1000;
      resetAt = base + lowest.windowSeconds * 1000;
    }
    if (resetAt) {
      const mins = Math.max(0, Math.round((resetAt - Date.now()) / 60000));
      const label = mins >= 1440 ? t("resetInDays", { n: Math.round(mins / 1440) })
        : mins >= 60 ? t("resetInHours", { n: Math.round(mins / 60) })
        : t("resetInMins", { n: mins });
      right.append(el("div", "quota-summary-meta", label.toUpperCase()));
    }
    right.append(el("div", "quota-summary-meta",
      t("usedPct", { n: lowest.usedPct }).toUpperCase()));
  }
  row.append(right);
  strip.append(row);
  return strip;
}

/** Codex web-dashboard extras not surfaced as quota windows — port of the
 * macOS `detailParts` second metadata line. Empty for providers/sources
 * that leave these fields undefined. */
function extrasParts(status: ProviderStatus): string[] {
  const parts: string[] = [];
  if (status.id === "codex" && status.creditsRemaining !== undefined) {
    parts.push(`$${status.creditsRemaining.toFixed(2)} credits`);
  }
  if (status.codeReviewRemainingPercent !== undefined) {
    parts.push(`Code review ${status.codeReviewRemainingPercent}%`);
  }
  if (status.creditsHistoryCount !== undefined) {
    parts.push(t("creditsHistoryCount", { n: status.creditsHistoryCount }));
  }
  return parts;
}

/**
 * Design TRAY toggle: mono label + square switch (no health glyph).
 * Persists `showInTray` on the provider row in settings.json (default true).
 */
function menuBarVisibilityToggle(providerId: string, hasError: boolean): HTMLElement {
  const wrap = el("div", "mb-vis");
  wrap.title = t("popover.menuBarVisibility");
  const label = el("span", hasError ? "mb-vis-label err" : "mb-vis-label", t("popover.tray").toUpperCase());
  wrap.append(label);

  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "mb-vis-switch";
  btn.setAttribute("role", "switch");
  const knob = el("span", "mb-vis-knob");
  btn.append(knob);

  let isOn = true; // default shown (macOS MenuBarVisibility default true)

  const paint = () => {
    btn.classList.toggle("on", isOn);
    btn.setAttribute("aria-checked", isOn ? "true" : "false");
    btn.title = isOn ? t("popover.visibilityOn") : t("popover.visibilityOff");
  };
  paint();

  type SettingsShape = {
    version?: number;
    providers: { id: string; showInTray?: boolean | null; [k: string]: unknown }[];
  };

  void invoke<SettingsShape>("get_settings")
    .then((s) => {
      const row = s.providers.find((p) => p.id === providerId);
      isOn = row?.showInTray !== false;
      paint();
    })
    .catch(() => {});

  btn.addEventListener("click", (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    isOn = !isOn;
    paint();
    void (async () => {
      try {
        const s = await invoke<SettingsShape>("get_settings");
        let row = s.providers.find((p) => p.id === providerId);
        if (!row) {
          row = { id: providerId, showInTray: isOn };
          s.providers.push(row);
        } else {
          row.showInTray = isOn;
        }
        await invoke("save_settings", { settings: s });
        // Rebuild tray frames (and keep tab order) like macOS menuBarVisibilityChanged.
        await emit(PROVIDERS_CHANGED_EVENT).catch(() => {});
      } catch {
        // Revert UI if save failed.
        isOn = !isOn;
        paint();
      }
    })();
  });

  wrap.append(btn);
  return wrap;
}

/** Logo plate + mono mark — plate bg and mask ink must be separate nodes
 * (mask uses background-color as ink; putting plate fill on the same node
 * made the icon look washed/blurry). */
function providerLogoPlate(id: string): HTMLElement {
  const plate = el("div", "provider-logo-plate");
  plate.append(logoMark(id, "provider-logo-ink tab-logo-mono"));
  return plate;
}

/** macOS LoadingQuotaSkeleton — three grey placeholder bars shown while a
 * provider's first fetch is still in flight. */
export function loadingSkeleton(): HTMLElement {
  const wrap = el("div", "quota-skeleton");
  wrap.append(el("div", "skeleton-bar w-narrow"));
  wrap.append(el("div", "skeleton-bar w-full"));
  wrap.append(el("div", "skeleton-bar w-mid"));
  return wrap;
}

/** Design provider header: logo tile · name + PLAN · SOURCE · RELATIVE · TRAY. */
function providerHeaderCard(status: ProviderStatus): HTMLElement {
  const card = el("section", "card provider-header-card");
  const row = el("div", "provider-head-row");
  const textCol = el("div", "provider-head-text");
  textCol.append(el("div", "provider-name", status.displayName));

  if (status.pending) {
    textCol.append(el("div", "provider-meta", t("provider.loading")));
  } else {
    // Design: plan · source · relative (no email clutter in popover).
    const meta: string[] = [];
    const plan = planLabel(status);
    if (plan) meta.push(plan);
    if (status.sourceLabel?.trim()) meta.push(status.sourceLabel.trim());
    if (meta.length === 0 && !isHidePersonalInfo()) {
      if (status.accountLabel) meta.push(status.accountLabel);
      else if (status.signedInEmail) meta.push(status.signedInEmail);
    }
    const updated = relativeUpdated(status.lastUpdated);
    if (updated) meta.push(updated);
    if (meta.length > 0) {
      textCol.append(el("div", "provider-meta", meta.join(" · ").toUpperCase()));
    }
  }

  row.append(
    providerLogoPlate(status.id),
    textCol,
    menuBarVisibilityToggle(status.id, !!status.error && !status.pending),
  );
  card.append(row);

  // macOS ServiceStatusStrip — issue badge (Claude/Codex) or link-only (Grok).
  const statusStrip = serviceStatusStrip(status);
  if (statusStrip) card.append(statusStrip);

  return card;
}

/** Public status-page URL for popover strip / Settings links. */
function statusPageURL(providerId: string): string | null {
  switch (providerId) {
    case "claude":
      return "https://status.claude.com/";
    case "codex":
    case "openai":
      return "https://status.openai.com/";
    case "grok":
    case "xai":
      return "https://status.x.ai";
    default:
      return null;
  }
}

function isLinkOnlyStatus(providerId: string): boolean {
  return providerId === "grok" || providerId === "xai";
}

/** Binary health for the strip: green / red / gray (macOS ProviderStatusPage.Health). */
type ServiceHealth = "ok" | "issue" | "unknown";

function serviceHealth(
  status: ProviderStatus,
): { health: ServiceHealth; label: string } {
  if (isLinkOnlyStatus(status.id) || !isStatusChecksEnabled()) {
    return { health: "unknown", label: t("provider.serviceStatus.unknown") };
  }
  const level = status.serviceStatusLevel;
  if (!level) {
    return { health: "unknown", label: t("provider.serviceStatus.unknown") };
  }
  if (level === "none") {
    const raw = status.serviceStatus?.trim();
    return {
      health: "ok",
      label: raw
        ? (raw === "All Systems Operational" ? t("provider.allOperational") : raw)
        : t("provider.serviceStatus.ok"),
    };
  }
  const raw = status.serviceStatus?.trim();
  return {
    health: "issue",
    label: raw || t("provider.serviceStatus.issue"),
  };
}

/**
 * Compact status-page row under the provider header (macOS `ServiceStatusStrip`).
 * Always shown for Claude / Codex / Grok: green = ok, red = issue, gray =
 * unknown, plus a trailing status-page link.
 */
function serviceStatusStrip(status: ProviderStatus): HTMLElement | null {
  const url = statusPageURL(status.id);
  if (!url) return null;

  const { health, label } = serviceHealth(status);
  const row = document.createElement("button");
  row.type = "button";
  row.className = "service-status-strip";
  row.title = url;

  row.append(el("span", `service-status-dot ${health}`));
  row.append(el("span", "service-status-text", label));
  row.append(el("span", "service-status-spacer"));
  row.append(el("span", "service-status-link", t("link.status")));
  row.append(el("span", "service-status-open", "↗"));
  row.addEventListener("click", (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    void openUrl(url).catch(() => {});
  });
  return row;
}

/** macOS `ProviderCard` — summary strip + divider + window rows (or error). */
function providerBodyCard(
  status: ProviderStatus,
  onRetry?: () => void,
  onFix?: () => void,
): HTMLElement {
  const card = el("section", "card provider-body-card");

  if (status.pending) {
    card.append(loadingSkeleton());
    return card;
  }
  if (status.error) {
    // Raw error text first (synchronous paint); the classifier round-trip
    // below swaps it for the localized, actionable hint and decides whether
    // "Fix" belongs next to Retry. Raw text stays reachable via the title
    // attribute (macOS keeps it in the row `.help()` tooltip the same way).
    const errorBox = el("div", "provider-error", status.error);
    errorBox.title = status.error;
    card.append(errorBox);

    // Retry is always available for a provider error; Fix only shows for
    // config/credential/cookie kinds — never for rate-limit/network, which
    // Settings can't do anything about.
    const actions = el("div", "provider-error-actions");
    const retry = el("button", "sw-pill-btn", currentLang() === "vi" ? "Thử lại" : "Retry");
    retry.addEventListener("click", () => onRetry?.());
    actions.append(retry);
    card.append(actions);

    void invoke<string | null>("classify_provider_error", { raw: status.error })
      .then((suffix) => {
        if (!suffix) return;
        errorBox.textContent = t(`providerError.${suffix}.hint`);
        return invoke<boolean>("is_fixable_provider_error", { raw: status.error });
      })
      .then((fixable) => {
        if (!fixable) return;
        const fix = el("button", "sw-pill-btn", currentLang() === "vi" ? "Sửa" : "Fix");
        fix.addEventListener("click", () => onFix?.());
        actions.append(fix);
      })
      .catch(() => {});
    return card;
  }
  if (status.windows.length === 0) {
    card.append(el("div", "footnote", t("noQuota")));
    return card;
  }

  if (status.id === "antigravity") {
    for (const win of status.windows.slice(0, 4)) {
      card.append(windowRow(win, status.lastUpdated));
    }
    return card;
  }

  card.append(quotaSummaryStrip(status));
  card.append(el("div", "provider-divider", ""));
  for (const win of status.windows) {
    card.append(windowRow(win, status.lastUpdated));
  }

  const extras = extrasParts(status);
  if (extras.length > 0) {
    card.append(el("div", "provider-extras", extras.join(" · ")));
  }

  if (isProviderStorageEnabled()) {
    const storageRow = el("div", "provider-storage");
    card.append(storageRow);
    void invoke<number>("provider_storage", { id: status.id })
      .then((bytes) => invoke<string>("format_storage_bytes", { bytes }).then((formatted) => {
        if (bytes > 0) storageRow.textContent = `${t("providerStorageLabel")}: ${formatted}`;
      }))
      .catch(() => {});
  }

  return card;
}

/**
 * Full provider tab stack — macOS VStack of ProviderHeaderCard + ProviderCard.
 * Returns a wrapper so Claude Code card can insert after the whole stack.
 */
export function providerCard(
  status: ProviderStatus,
  onRetry?: () => void,
  onFix?: () => void,
): HTMLElement {
  const stack = el("div", "provider-stack");
  stack.append(providerHeaderCard(status));
  stack.append(providerBodyCard(status, onRetry, onFix));
  return stack;
}

/** Claude Code quick-apply card for the provider tab, shown only when the
 * provider can back Claude Code and already has an API key configured
 * (mirrors the Swift `shouldShow` gate). `onOpenSettings` jumps to the
 * Settings tab when the provider still needs its models configured. */
export async function claudeCodeQuickApplyCard(
  status: ProviderStatus,
  onOpenSettings?: () => void,
): Promise<HTMLElement | null> {
  if (!shouldShowClaudeCode(status.id, await providerApiKey(status.id))) return null;
  return claudeCodeCard(status.id, status.displayName, onOpenSettings);
}

async function providerApiKey(providerId: string): Promise<string | null> {
  try {
    const settings = await invoke<{ providers: { id: string; apiKey?: string | null }[] }>("get_settings");
    return settings.providers.find((p) => p.id === providerId)?.apiKey ?? null;
  } catch {
    return null;
  }
}
