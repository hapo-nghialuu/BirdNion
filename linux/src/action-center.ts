import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import type {
  ProviderRemediationTarget,
  ProviderStatus,
  StaleQuotaWarning,
} from "./provider-tab";

export const ACTION_CENTER_UPDATED_EVENT = "birdnion-action-center-updated";
export const ACTION_CENTER_SNAPSHOT_REQUEST_EVENT = "birdnion-action-center-snapshot-request";
export const ACTION_CENTER_RETRY_EVENT = "birdnion-action-center-retry";
export const GUIDED_SETUP_STATUS_EVENT = "birdnion-guided-setup-status";

export type ActionCenterIssue = {
  providerId: string;
  providerName: string;
  kind: "setup" | "connection";
  remediationTarget?: ProviderRemediationTarget;
};

export type ActionCenterSnapshot = {
  issues: ActionCenterIssue[];
  ready: boolean;
  error: boolean;
};

export type GuidedSetupProviderInput = {
  id: string;
  name: string;
  enabled: boolean;
  detectionReady?: boolean;
};

const SUPPORTED_PROVIDER_IDS = new Set(["claude", "codex", "grok"]);

export async function collectActionCenterIssues(
  statuses: ProviderStatus[],
  staleWarning: (id: string) => StaleQuotaWarning | undefined = () => undefined,
  providers: GuidedSetupProviderInput[] = [],
): Promise<ActionCenterIssue[]> {
  const statusById = new Map(statuses.map((status) => [status.id, status]));
  const projected = await Promise.all(providers.map(async (
    provider,
  ): Promise<[number, ActionCenterIssue] | null> => {
    if (!provider.enabled || !SUPPORTED_PROVIDER_IDS.has(provider.id)) return null;
    const status = statusById.get(provider.id);
    if (status?.pending) {
      return provider.detectionReady === false
        ? [0, {
            providerId: provider.id,
            providerName: status.displayName || provider.name,
            kind: "setup",
            remediationTarget: "setupSource",
          }]
        : null;
    }
    if (status?.error) {
      const [errorKind, target, transient] = await Promise.all([
        invoke<string | null>("classify_provider_error", { raw: status.error }),
        invoke<ProviderRemediationTarget | null>("provider_remediation_target", {
          providerId: provider.id,
          raw: status.error,
        }),
        invoke<boolean>("is_transient_provider_error", { raw: status.error }),
      ]);
      const priority = errorKind === "notConfigured" ? 0
        : target ? 1
        : transient ? 2
        : null;
      if (priority === null) return null;
      return [priority, {
        providerId: provider.id,
        providerName: status.displayName || provider.name,
        kind: target ? "setup" : "connection",
        remediationTarget: target ?? undefined,
      }];
    }
    if (staleWarning(provider.id)) {
      return [2, {
        providerId: provider.id,
        providerName: status?.displayName || provider.name,
        kind: "connection",
      }];
    }
    if ((!status || status.windows.length === 0) && provider.detectionReady === false) {
      return [0, {
        providerId: provider.id,
        providerName: status?.displayName || provider.name,
        kind: "setup",
        remediationTarget: "setupSource",
      }];
    }
    return null;
  }));
  return projected
    .filter((entry): entry is [number, ActionCenterIssue] => entry !== null)
    .sort((a, b) => a[0] - b[0])
    .slice(0, 3)
    .map(([, issue]) => issue);
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

type IssueSubscriber = (snapshot: ActionCenterSnapshot) => void;
const issueSubscribers = new Set<IssueSubscriber>();
let latestSnapshot: ActionCenterSnapshot | null = null;

/** Số việc đang mở theo snapshot gần nhất — dùng cho badge icon Action Center
 *  ở header mỗi pane Settings. `null` khi chưa nhận được snapshot nào. */
export function latestIssueCount(): number | null {
  return latestSnapshot ? latestSnapshot.issues.length : null;
}
let listenerStarted = false;

function ensureIssueListener() {
  if (listenerStarted) return;
  listenerStarted = true;
  void listen<ActionCenterSnapshot>(ACTION_CENTER_UPDATED_EVENT, (event) => {
    latestSnapshot = event.payload;
    for (const subscriber of issueSubscribers) subscriber(event.payload);
  }).catch(() => { listenerStarted = false; });
}

export async function actionCenterPane(
  onFix: (providerId: string, target: ProviderRemediationTarget) => void,
): Promise<HTMLElement> {
  const page = el("div", "settings-page action-center-page");
  const header = el("div", "sw-pane-header");
  header.append(
    el("div", "sw-pane-title", t("actionCenterTitle")),
    el("div", "sw-pane-subtitle", t("actionCenterSubtitle")),
  );
  page.append(header);

  const body = el("div", "action-center-body");
  page.append(body);
  let receivedSnapshot = latestSnapshot !== null;

  const renderLoadFailure = () => {
    body.textContent = "";
    const failed = el("div", "action-center-empty");
    failed.append(el("div", "action-center-empty-title", t("loadError")));
    const retry = el("button", "sw-pill-btn", t("actionCenterRetry")) as HTMLButtonElement;
    retry.addEventListener("click", () => {
      body.textContent = "";
      body.append(el("div", "loading", "…"));
      void emit(ACTION_CENTER_SNAPSHOT_REQUEST_EVENT).catch(renderLoadFailure);
    });
    failed.append(retry);
    body.append(failed);
  };

  const render = (issues: ActionCenterIssue[]) => {
    body.textContent = "";
    if (issues.length === 0) {
      const empty = el("div", "action-center-empty");
      empty.append(
        el("div", "action-center-empty-title", t("actionCenterEmptyTitle")),
        el("div", "action-center-empty-body", t("actionCenterEmptyBody")),
      );
      body.append(empty);
      return;
    }

    body.append(el("div", "sw-section-header", t("actionCenterCurrent").toUpperCase()));
    for (const issue of issues) {
      const row = el("div", "action-center-row");
      const copy = el("div", "action-center-copy");
      copy.append(
        el("div", "action-center-row-title",
          `${issue.providerName} · ${t(`actionCenter.${issue.kind}.title`)}`),
        el("div", "action-center-row-hint", t(`actionCenter.${issue.kind}.hint`)),
      );
      const button = el(
        "button",
        issue.remediationTarget ? "save-button" : "sw-pill-btn",
        issue.remediationTarget ? t("actionCenterFix") : t("actionCenterRetry"),
      ) as HTMLButtonElement;
      button.addEventListener("click", () => {
        if (issue.remediationTarget) {
          onFix(issue.providerId, issue.remediationTarget);
          return;
        }
        button.disabled = true;
        void emit(ACTION_CENTER_RETRY_EVENT, { providerId: issue.providerId })
          .catch(() => { button.disabled = false; });
      });
      row.append(copy, button);
      body.append(row);
    }
  };

  const renderSnapshot = (snapshot: ActionCenterSnapshot) => {
    if (snapshot.error) {
      renderLoadFailure();
      return;
    }
    if (!snapshot.ready && snapshot.issues.length === 0) {
      body.textContent = "";
      body.append(el("div", "loading", "…"));
      return;
    }
    render(snapshot.issues);
  };

  const subscriber: IssueSubscriber = (snapshot) => {
    if (!page.isConnected) {
      issueSubscribers.delete(subscriber);
      return;
    }
    receivedSnapshot = true;
    renderSnapshot(snapshot);
  };
  issueSubscribers.add(subscriber);
  ensureIssueListener();
  if (latestSnapshot) renderSnapshot(latestSnapshot);
  else body.append(el("div", "loading", "…"));

  requestAnimationFrame(() => {
    void emit(ACTION_CENTER_SNAPSHOT_REQUEST_EVENT).catch(renderLoadFailure);
    window.setTimeout(() => {
      if (!receivedSnapshot && page.isConnected) renderLoadFailure();
    }, 3_000);
  });
  return page;
}
