// Per-provider quota view — port of the macOS ProviderCard: quota windows
// with remaining-% bars, error banner, account metadata line.

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";
import { claudeCodeCard, shouldShowClaudeCode } from "./claude-code";

export type QuotaWindow = {
  label: string;
  usedPct: number;
  remainingPct: number;
  subtitle?: string;
  resetsAt?: number;
};

export type ProviderStatus = {
  id: string;
  displayName: string;
  windows: QuotaWindow[];
  lastUpdated: number;
  error?: string;
  accountLabel?: string;
  creditsRemaining?: number;
};

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function quotaTone(remaining: number): string {
  if (remaining <= 20) return "critical";
  if (remaining <= 50) return "warning";
  return "ok";
}

function windowRow(win: QuotaWindow): HTMLElement {
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
  if (win.resetsAt) {
    const mins = Math.max(0, Math.round((win.resetsAt * 1000 - Date.now()) / 60000));
    const label = mins >= 1440 ? t("resetInDays", { n: Math.round(mins / 1440) })
      : mins >= 60 ? t("resetInHours", { n: Math.round(mins / 60) })
      : t("resetInMins", { n: mins });
    foot.append(el("span", "window-subtitle", label));
  }
  row.append(foot);
  return row;
}

export function providerCard(status: ProviderStatus): HTMLElement {
  const card = el("section", "card");
  const head = el("div", "provider-head");
  head.append(el("div", "provider-name", status.displayName));
  const meta: string[] = [];
  if (status.accountLabel) meta.push(status.accountLabel);
  const updated = new Date(status.lastUpdated * 1000);
  meta.push(`cập nhật ${updated.getHours()}:${String(updated.getMinutes()).padStart(2, "0")}`);
  head.append(el("div", "provider-meta", meta.join(" · ")));
  card.append(head);

  if (status.error) {
    card.append(el("div", "provider-error", status.error));
  } else if (status.windows.length === 0) {
    card.append(el("div", "footnote", t("noQuota")));
  } else {
    for (const win of status.windows) card.append(windowRow(win));
  }
  return card;
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
