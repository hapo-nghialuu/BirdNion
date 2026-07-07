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
  /** Codex web-dashboard extras (best-effort cookie enrichment) — port of
   * macOS `CodexWebExtras`. `codeReviewRemainingPercent` is never populated
   * on Linux (see provider backend docs). */
  signedInEmail?: string;
  codeReviewRemainingPercent?: number;
  creditsPurchaseUrl?: string;
  creditsHistoryCount?: number;
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

/** One-shot probe button through the provider's real fetch path (never the
 * whole refresh loop) — port of the macOS detail-header self-test button.
 * Runs `test_provider`, then classifies any error for an inline hint; the
 * raw error is available on hover via the `title` attribute. */
function selfTestWidget(providerId: string): HTMLElement {
  const wrap = el("span", "self-test-wrap");
  const button = document.createElement("button");
  button.type = "button";
  button.className = "self-test-btn";
  button.textContent = t("provider.selfTest");
  const result = el("div", "self-test-result");

  button.addEventListener("click", () => {
    if (button.disabled) return;
    button.disabled = true;
    result.className = "self-test-result running";
    result.textContent = t("provider.selfTest.running");
    result.removeAttribute("title");
    void invoke<ProviderStatus>("test_provider", { id: providerId })
      .then(async (status) => {
        if (status.error) {
          const suffix = (await invoke<string | null>("classify_provider_error", { raw: status.error })) ?? "unknown";
          result.className = "self-test-result fail";
          result.textContent = `${t("provider.selfTest.fail")} — ${t(`providerError.${suffix}.hint`)}`;
          result.title = status.error;
        } else {
          result.className = "self-test-result pass";
          result.textContent = t("provider.selfTest.pass");
        }
      })
      .catch((err) => {
        result.className = "self-test-result fail";
        result.textContent = `${t("provider.selfTest.fail")} — ${String(err)}`;
      })
      .finally(() => {
        button.disabled = false;
      });
  });

  wrap.append(button, result);
  return wrap;
}

export function providerCard(status: ProviderStatus): HTMLElement {
  const card = el("section", "card");
  const head = el("div", "provider-head");
  const nameRow = el("div", "provider-name-row");
  nameRow.append(el("div", "provider-name", status.displayName));
  nameRow.append(selfTestWidget(status.id));
  head.append(nameRow);
  const meta: string[] = [];
  if (status.accountLabel) meta.push(status.accountLabel);
  else if (status.signedInEmail) meta.push(status.signedInEmail);
  const updated = new Date(status.lastUpdated * 1000);
  meta.push(`cập nhật ${updated.getHours()}:${String(updated.getMinutes()).padStart(2, "0")}`);
  head.append(el("div", "provider-meta", meta.join(" · ")));
  card.append(head);

  const extras = extrasParts(status);
  if (extras.length > 0) {
    card.append(el("div", "provider-extras", extras.join(" · ")));
  }

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
