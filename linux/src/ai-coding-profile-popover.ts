import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";
import { settingsIcon } from "./settings-icons";

export type ProfileAgent = "claude" | "codex";
export type ProxyRuntimeFacts = {
  running: boolean;
  claudeProfileId: string | null;
  codexProfileId: string | null;
};
export type ProfileSwitchRow = {
  agent: ProfileAgent;
  profileId: string;
  name: string;
  expectedSnapshot: string;
  ready: boolean;
  active: boolean;
  current: boolean;
  usesProxy: boolean;
  targetPath: string | null;
  profileFlag: string | null;
};
export type ProfileSwitchCatalog = {
  claudeProfiles: ProfileSwitchRow[];
  codexProfiles: ProfileSwitchRow[];
  proxy: ProxyRuntimeFacts;
};
export type ProfileHealth = "needsSetup" | "ready" | "active" | "stale";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function proxyMatches(row: ProfileSwitchRow, proxy: ProxyRuntimeFacts): boolean {
  if (!row.usesProxy) return true;
  const profileId = row.agent === "claude" ? proxy.claudeProfileId : proxy.codexProfileId;
  return proxy.running && profileId === row.profileId;
}

export function profileHealth(row: ProfileSwitchRow, proxy: ProxyRuntimeFacts): ProfileHealth {
  if (!row.ready) return "needsSetup";
  if (row.active && row.current && proxyMatches(row, proxy)) return "active";
  if (row.active || row.current) return "stale";
  return "ready";
}

function stateLabel(health: ProfileHealth): string {
  return t(`profileSwitchState.${health}`);
}

function profilesFor(agent: ProfileAgent, catalog: ProfileSwitchCatalog): ProfileSwitchRow[] {
  return agent === "claude" ? catalog.claudeProfiles : catalog.codexProfiles;
}

/** Safe, collapsible custom-profile switcher. The webview receives only an
 * opaque snapshot proof; provider credentials stay in Rust. */
export function aiCodingProfilePopoverCard(
  agent: ProfileAgent,
  onResize: () => void,
  onOpenSettings: () => void,
): HTMLElement {
  const card = el("section", "card fm-pop-card ai-profile-card");
  const expandKey = `birdnion.${agent}ProfilesExpanded`;
  let expanded = localStorage.getItem(expandKey) === "true";
  let catalog: ProfileSwitchCatalog | null = null;
  let busyId: string | null = null;
  let errorText = "";
  card.hidden = true;

  const reload = async () => {
    catalog = await invoke<ProfileSwitchCatalog>("profile_catalog");
    render();
    onResize();
  };

  const activate = async (row: ProfileSwitchRow) => {
    if (!catalog || busyId) return;
    const health = profileHealth(row, catalog.proxy);
    if (health === "active") return;
    if (health === "needsSetup") {
      onOpenSettings();
      return;
    }
    busyId = row.profileId;
    errorText = "";
    render();
    try {
      const command = agent === "claude" ? "activate_claude_profile" : "activate_codex_profile";
      await invoke(command, {
        request: { profileId: row.profileId, expectedSnapshot: row.expectedSnapshot },
      });
    } catch (error) {
      errorText = String(error);
    } finally {
      busyId = null;
      await reload().catch((error) => {
        errorText = String(error);
        render();
      });
    }
  };

  const render = () => {
    card.textContent = "";
    if (!catalog && !errorText) {
      card.hidden = true;
      return;
    }
    const profiles = catalog ? profilesFor(agent, catalog) : [];
    card.hidden = profiles.length === 0 && !errorText;
    if (card.hidden) return;

    const head = el("button", "fm-pop-head");
    head.setAttribute("type", "button");
    head.setAttribute("aria-expanded", String(expanded));
    const icon = el("span", "fm-pop-icon");
    icon.append(settingsIcon("terminal", "fm-pop-icon-svg"));
    const titles = el("span", "fm-pop-titles");
    titles.append(el("span", "fm-pop-title", t(`profileSwitchTitle.${agent}`)));
    const active = catalog && profiles.find((row) => profileHealth(row, catalog!.proxy) === "active");
    titles.append(el("span", "fm-pop-active", active?.name || t("profileSwitchCustom")));
    head.append(icon, titles);
    if (catalog) head.append(el("span", "fm-pop-count", String(profiles.length)));
    head.append(el("span", "fm-pop-chevron", expanded ? "▴" : "▾"));
    head.addEventListener("click", () => {
      expanded = !expanded;
      localStorage.setItem(expandKey, String(expanded));
      render();
      onResize();
    });
    card.append(head);

    if (!expanded || !catalog) return;
    const list = el("div", "fm-pop-list");
    for (const row of profiles) {
      const health = profileHealth(row, catalog.proxy);
      const button = document.createElement("button");
      button.className = `fm-pop-row ai-profile-row ${health}`;
      button.setAttribute("type", "button");
      button.disabled = busyId !== null || health === "active";
      button.setAttribute("aria-label", `${row.name}, ${stateLabel(health)}`);
      button.append(el("span", `ai-profile-health ${health}`));
      const name = el("span", "fm-pop-name-col");
      name.append(
        el("span", "fm-pop-name", row.name),
        el("span", "fm-pop-sub", row.targetPath || row.profileFlag || t("profileSwitchNeedsSetup")),
      );
      button.append(name, el(
        "span",
        `ai-profile-state ${health}`,
        busyId === row.profileId ? "…" : stateLabel(health),
      ));
      button.addEventListener("click", () => { void activate(row); });
      list.append(button);
    }
    if (errorText) list.append(el("div", "ai-profile-error", errorText));
    card.append(list);
  };

  render();
  void reload().catch((error) => {
    errorText = String(error);
    expanded = true;
    catalog = { claudeProfiles: [], codexProfiles: [], proxy: {
      running: false, claudeProfileId: null, codexProfileId: null,
    } };
    render();
  });
  return card;
}
