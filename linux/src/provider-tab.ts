// Per-provider quota view — port of the macOS ProviderCard: quota windows
// with remaining-% bars, error banner, account metadata line, and the
// menu-bar visibility toggle (macOS `MenuBarVisibilityToggle`).

import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { claudeCodeCard, shouldShowClaudeCode } from "./claude-code";
import { isProviderStorageEnabled, isHidePersonalInfo } from "./settings-about";
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

function quotaTone(remaining: number): string {
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

function lowestWindow(status: ProviderStatus): QuotaWindow | null {
  if (!status.windows.length) return null;
  return status.windows.reduce((a, b) => (a.remainingPct < b.remainingPct ? a : b));
}

/** macOS `WindowRow` — label · % · 5px bar · used · reset. */
function windowRow(win: QuotaWindow, lastUpdated: number): HTMLElement {
  const row = el("div", "window-row");
  const head = el("div", "window-head");
  head.append(el("span", "window-label", win.label));
  head.append(el("span", `window-pct ${quotaTone(win.remainingPct)}`, `${win.remainingPct}%`));
  const track = el("div", "window-track");
  const fill = el("div", `window-fill ${quotaTone(win.remainingPct)}`);
  fill.style.width = `${Math.max(0, Math.min(100, win.remainingPct))}%`;
  track.append(fill);
  row.append(head, track);
  const foot = el("div", "window-foot");
  foot.append(el("span", "window-subtitle",
    win.subtitle ?? t("usedPct", { n: win.usedPct })));
  // Prefer API resetsAt; fall back to lastUpdated + windowSeconds like macOS.
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
    foot.append(el("span", "window-subtitle", label));
  }
  row.append(foot);
  return row;
}

/** macOS `QuotaSummaryStrip` — "Quota thấp nhất" + window name + big %. */
function quotaSummaryStrip(status: ProviderStatus): HTMLElement {
  const lowest = lowestWindow(status);
  const strip = el("div", "quota-summary");
  const left = el("div", "quota-summary-left");
  left.append(el("div", "quota-summary-label", t("popover.lowestQuota")));
  left.append(el("div", "quota-summary-window",
    lowest?.label ?? status.displayName));
  strip.append(left);
  const pct = lowest?.remainingPct ?? 0;
  strip.append(el("div", `quota-summary-pct ${quotaTone(pct)}`, `${pct}%`));
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

/** SF-style checkmark / warning glyph (crisper than text “✓”). */
function healthIcon(hasError: boolean): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", `mb-vis-health-svg${hasError ? " err" : " ok"}`);
  if (hasError) {
    // SF exclamationmark.triangle.fill
    svg.innerHTML =
      '<path fill="currentColor" d="M7.05 2.55a1.1 1.1 0 0 1 1.9 0l5.85 10.2A1.1 1.1 0 0 1 13.85 14.3H2.15a1.1 1.1 0 0 1-.95-1.55l5.85-10.2z"/>'
      + '<rect x="7.35" y="5.6" width="1.3" height="4" rx="0.55" fill="#fff"/>'
      + '<circle cx="8" cy="11.55" r="0.85" fill="#fff"/>';
  } else {
    // SF checkmark.circle.fill
    svg.innerHTML =
      '<circle cx="8" cy="8" r="7.1" fill="currentColor"/>'
      + '<path fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" d="M4.6 8.15l2.25 2.25L11.5 5.7"/>';
  }
  return svg;
}

/**
 * macOS `MenuBarVisibilityToggle`: health glyph + capsule switch controlling
 * whether this provider rotates on the tray / menu bar percent readout.
 * Persists `showInTray` on the provider row in settings.json (default true).
 */
function menuBarVisibilityToggle(providerId: string, hasError: boolean): HTMLElement {
  const wrap = el("div", "mb-vis");
  wrap.title = t("popover.menuBarVisibility");
  wrap.append(healthIcon(hasError));

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

/** macOS `ProviderHeaderCard` — logo · name/meta · MenuBarVisibilityToggle. */
function providerHeaderCard(status: ProviderStatus): HTMLElement {
  const card = el("section", "card provider-header-card");
  const row = el("div", "provider-head-row");
  const textCol = el("div", "provider-head-text");
  textCol.append(el("div", "provider-name", status.displayName));

  if (status.pending) {
    textCol.append(el("div", "provider-meta", t("provider.loading")));
  } else {
    const meta: string[] = [];
    if (!isHidePersonalInfo()) {
      if (status.accountLabel) meta.push(status.accountLabel);
      else if (status.signedInEmail) meta.push(status.signedInEmail);
    }
    const plan = planLabel(status);
    if (plan) meta.push(plan);
    // macOS includes sourceLabel on the metadata line when present.
    if (status.sourceLabel?.trim()) meta.push(status.sourceLabel.trim());
    const updated = relativeUpdated(status.lastUpdated);
    if (updated) meta.push(updated);
    if (meta.length > 0) textCol.append(el("div", "provider-meta", meta.join(" · ")));
  }

  row.append(
    providerLogoPlate(status.id),
    textCol,
    menuBarVisibilityToggle(status.id, !!status.error && !status.pending),
  );
  card.append(row);
  return card;
}

/** macOS `ProviderCard` — summary strip + divider + window rows (or error). */
function providerBodyCard(status: ProviderStatus): HTMLElement {
  const card = el("section", "card provider-body-card");

  if (status.pending) {
    card.append(loadingSkeleton());
    return card;
  }
  if (status.error) {
    card.append(el("div", "provider-error", status.error));
    return card;
  }
  if (status.windows.length === 0) {
    card.append(el("div", "footnote", t("noQuota")));
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
export function providerCard(status: ProviderStatus): HTMLElement {
  const stack = el("div", "provider-stack");
  stack.append(providerHeaderCard(status));
  stack.append(providerBodyCard(status));
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
