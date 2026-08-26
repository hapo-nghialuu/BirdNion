import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const tauriStubs = new Map(Object.entries({
  "@tauri-apps/api/core": "export async function invoke() { throw new Error('unused in unit test'); }",
  "@tauri-apps/api/app": "export async function getVersion() { return 'test'; }",
  "@tauri-apps/api/event": "export async function emit() {} export async function listen() { return () => {}; }",
  "@tauri-apps/api/window": "export function getCurrentWindow() { return {}; }",
  "@tauri-apps/plugin-opener": "export async function openUrl() {}",
  "@tauri-apps/plugin-dialog": "export async function open() {} export async function ask() { return false; }",
}).map(([specifier, source]) => [specifier, `data:text/javascript,${encodeURIComponent(source)}`]));

registerHooks({
  resolve(specifier, context, nextResolve) {
    const stub = tauriStubs.get(specifier);
    if (stub) return { url: stub, shortCircuit: true };
    const relativeWithoutExtension = (specifier.startsWith("./") || specifier.startsWith("../"))
      && !/[.]([cm]?js|ts|json)$/.test(specifier);
    return nextResolve(relativeWithoutExtension ? `${specifier}.ts` : specifier, context);
  },
});

const {
  changedProviderSettingsStatusIds,
  clearProviderSettingsStatus,
  createProviderSettingsGenerationGate,
  installListenersBeforeLifecycleArm,
  NAME_BY_ID,
  reconcileCanonicalSettingsSnapshot,
  reconcileCompletedSettingsSave,
} = await import("../src/settings-tab.ts");

test("Linux Settings roster exposes xAI in the macOS provider position", () => {
  const ids = [...NAME_BY_ID.keys()];
  assert.equal(NAME_BY_ID.get("xai"), "xAI");
  assert.equal(ids.indexOf("xai"), ids.indexOf("grok") + 1);
  assert.equal(ids.indexOf("openai"), ids.indexOf("xai") + 1);
});

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function settings(revision, apiKey, activeAccount = "account-a") {
  return {
    version: 1,
    settingsRevision: revision,
    active_codex_account: activeAccount,
    providers: [
      { id: "openrouter", enabled: true, apiKey, accountLabel: "Primary" },
      { id: "codex", enabled: true },
    ],
  };
}

test("listener lifecycle arms only after a deferred final registration installs", async () => {
  const second = deferred();
  const unlistened = [];
  let installed = [];
  let lifecycleArmed = false;
  const registration = installListenersBeforeLifecycleArm(
    [
      async () => () => unlistened.push("first"),
      () => second.promise,
    ],
    (unlisteners) => { installed = unlisteners; },
    () => { lifecycleArmed = true; },
  );

  await Promise.resolve();
  await Promise.resolve();
  assert.equal(lifecycleArmed, false, "crossing a frame cannot dispose a partial listener set");
  assert.deepEqual(installed, []);

  second.resolve(() => unlistened.push("second"));
  await registration;
  assert.equal(lifecycleArmed, true);
  assert.equal(installed.length, 2);
  installed.forEach((unlisten) => unlisten());
  assert.deepEqual(unlistened, ["first", "second"]);
});

test("newer event snapshot stays authoritative when the provider form is clean", () => {
  const base = settings(4, "saved-key");
  const canonical = settings(5, "canonical-key", "account-b");

  const result = reconcileCanonicalSettingsSnapshot(base, structuredClone(base), canonical);

  assert.deepEqual(result.settings, canonical);
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.hasLocalChanges, false);
});

test("newer event snapshot rebases over a dirty form without dropping its unsaved API key", () => {
  const base = settings(4, "saved-key");
  const local = structuredClone(base);
  local.providers[0].apiKey = "typed-but-unsaved";
  const canonical = settings(5, "saved-key", "account-b");
  canonical.providers[0].accountLabel = "Renamed elsewhere";

  const result = reconcileCanonicalSettingsSnapshot(base, local, canonical);

  assert.equal(result.settings.settingsRevision, 5);
  assert.equal(result.settings.active_codex_account, "account-b");
  assert.equal(result.settings.providers[0].apiKey, "typed-but-unsaved");
  assert.equal(result.settings.providers[0].accountLabel, "Renamed elsewhere");
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.hasLocalChanges, true);
});

test("same-field cross-window edit keeps the draft but reports a fail-safe conflict", () => {
  const base = settings(4, "saved-key");
  const local = structuredClone(base);
  local.providers[0].apiKey = "typed-but-unsaved";
  const canonical = settings(5, "changed-in-other-window", "account-b");

  const result = reconcileCanonicalSettingsSnapshot(base, local, canonical);

  assert.equal(result.settings.settingsRevision, 5);
  assert.equal(result.settings.active_codex_account, "account-b");
  assert.equal(result.settings.providers[0].apiKey, "typed-but-unsaved");
  assert.deepEqual(result.conflicts, ["providers.openrouter.apiKey"]);
  assert.equal(result.hasLocalChanges, true);
});

test("an edit made during a delayed save stays dirty after only the submitted snapshot persists", () => {
  const submitted = settings(4, "draft-a");
  const live = structuredClone(submitted);
  live.providers[0].apiKey = "draft-b-typed-during-save";

  const result = reconcileCompletedSettingsSave(submitted, live, 5);

  assert.equal(result.canonical.settingsRevision, 5);
  assert.equal(result.canonical.providers[0].apiKey, "draft-a");
  assert.equal(result.settings.settingsRevision, 5);
  assert.equal(result.settings.providers[0].apiKey, "draft-b-typed-during-save");
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.hasLocalChanges, true);
});

test("newer settings status generation wins over a late prior completion", async () => {
  const gate = createProviderSettingsGenerationGate();
  const accountA = deferred();
  const accountB = deferred();
  let published = null;
  const refresh = async (completion) => {
    const generation = gate.beginRefresh(["codex"]).get("codex");
    const status = await completion.promise;
    if (gate.isCurrent(generation)) published = status;
  };

  const staleRefresh = refresh(accountA);
  const currentRefresh = refresh(accountB);
  accountB.resolve({ id: "codex", account: "B" });
  await currentRefresh;
  accountA.resolve({ id: "codex", account: "A" });
  await staleRefresh;

  assert.deepEqual(published, { id: "codex", account: "B" });
});

test("Codex account invalidation clears status and rejects its pending completion", async () => {
  const gate = createProviderSettingsGenerationGate();
  const accountA = deferred();
  let statuses = [{ id: "codex", account: "A" }];
  const generation = gate.begin("codex");
  const pending = accountA.promise.then((status) => {
    if (gate.isCurrent(generation)) statuses = [status];
  });

  gate.invalidate("codex");
  statuses = statuses.filter((status) => status.id !== "codex");
  accountA.resolve({ id: "codex", account: "A-late" });
  await pending;

  assert.deepEqual(statuses, []);
});

test("same Codex provider and result node cannot accept a self-test from the prior account", async () => {
  const gate = createProviderSettingsGenerationGate();
  const accountA = deferred();
  const resultNode = { isConnected: true, state: "running" };
  let selectedId = "codex";
  let status = null;
  const generation = gate.begin("codex");
  const pending = accountA.promise.then((result) => {
    if (!gate.isCurrent(generation)
      || selectedId !== "codex"
      || !resultNode.isConnected) return;
    status = result;
    resultNode.state = "pass";
  });

  gate.invalidate("codex");
  accountA.resolve({ id: "codex", account: "A" });
  await pending;

  assert.equal(selectedId, "codex");
  assert.equal(resultNode.isConnected, true);
  assert.equal(status, null);
  assert.equal(resultNode.state, "running");
});

test("durable config switch clears stale A before B status completes with an error", async () => {
  const gate = createProviderSettingsGenerationGate();
  const durableSave = deferred();
  const accountB = deferred();
  const statusCleared = deferred();
  const remediationTargets = new Map([["codex", "credential"]]);
  let statuses = [
    { id: "claude", account: "C" },
    { id: "codex", account: "A", windows: [{ remainingPct: 80 }] },
  ];
  const saveAndRefresh = (async () => {
    await durableSave.promise;
    gate.invalidate("codex");
    statuses = clearProviderSettingsStatus(statuses, remediationTargets, "codex");
    const generation = gate.beginRefresh(["codex"]).get("codex");
    statusCleared.resolve();
    const status = await accountB.promise;
    if (gate.isCurrent(generation)) statuses.push(status);
  })();

  assert.equal(statuses.find((status) => status.id === "codex")?.account, "A");
  durableSave.resolve();
  await statusCleared.promise;
  assert.equal(statuses.some((status) => status.id === "codex"), false);
  assert.equal(remediationTargets.has("codex"), false);

  accountB.resolve({ id: "codex", account: "B", error: "timeout", windows: [] });
  await saveAndRefresh;
  assert.equal(statuses.find((status) => status.id === "codex")?.account, "B");
  assert.equal(statuses.find((status) => status.id === "codex")?.error, "timeout");
});

test("canonical account snapshot clears A before deferred B completion", async () => {
  const previous = settings(7, "saved-key");
  previous.active_freemodel_account = "account-a";
  previous.providers.push({
    id: "freemodel",
    enabled: true,
    source: "browser",
    cookieSource: "auto",
  });
  const next = structuredClone(previous);
  next.settingsRevision = 8;
  next.active_freemodel_account = "account-b";

  assert.deepEqual(changedProviderSettingsStatusIds(previous, next), ["freemodel"]);

  const gate = createProviderSettingsGenerationGate();
  const accountB = deferred();
  const statusCleared = deferred();
  const remediationTargets = new Map([
    ["claude", "credential"],
    ["freemodel", "cookieSource"],
  ]);
  let statuses = [
    { id: "claude", account: "C" },
    { id: "freemodel", account: "A", windows: [{ remainingPct: 70 }] },
  ];
  const applySnapshot = (async () => {
    for (const providerId of changedProviderSettingsStatusIds(previous, next)) {
      gate.invalidate(providerId);
      statuses = clearProviderSettingsStatus(statuses, remediationTargets, providerId);
    }
    const generation = gate.beginRefresh(["freemodel"]).get("freemodel");
    statusCleared.resolve();
    const status = await accountB.promise;
    if (gate.isCurrent(generation)) statuses.push(status);
  })();

  await statusCleared.promise;
  assert.equal(statuses.some((status) => status.id === "freemodel"), false);
  assert.equal(statuses.find((status) => status.id === "claude")?.account, "C");
  assert.equal(remediationTargets.has("freemodel"), false);
  assert.equal(remediationTargets.has("claude"), true);

  accountB.resolve({ id: "freemodel", account: "B", error: "timeout", windows: [] });
  await applySnapshot;
  assert.equal(statuses.find((status) => status.id === "freemodel")?.account, "B");
});

test("canonical provider config comparison covers source, cookie, credential, and enablement", () => {
  const previous = settings(9, "key-a");
  const next = structuredClone(previous);
  next.settingsRevision = 10;
  next.providers[0].apiKey = "key-b";
  next.providers[0].source = "browser";
  next.providers[0].cookieSource = "manual";
  next.providers[1].enabled = false;

  assert.deepEqual(
    changedProviderSettingsStatusIds(previous, next).sort(),
    ["codex", "openrouter"],
  );
});
