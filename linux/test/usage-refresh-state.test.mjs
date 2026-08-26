import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import ts from "typescript";

import { resolveRefreshedUsageReport } from "../src/usage.ts";

const tauriStubs = new Map(Object.entries({
  "@tauri-apps/api/core": "export async function invoke() { throw new Error('unused in unit test'); }",
  "@tauri-apps/api/app": "export async function getVersion() { return 'test'; }",
  "@tauri-apps/api/event": "export async function emit() {} export async function listen() { return () => {}; }",
  "@tauri-apps/api/window": `
    export async function currentMonitor() { return null; }
    export function getCurrentWindow() {
      return { onFocusChanged: async () => () => {} };
    }
  `,
  "@tauri-apps/api/dpi": "export class LogicalSize { constructor(width, height) { this.width = width; this.height = height; } }",
  "@tauri-apps/plugin-opener": "export async function openUrl() {}",
  "@tauri-apps/plugin-dialog": "export async function open() {} export async function ask() { return false; }",
}).map(([specifier, source]) => [specifier, `data:text/javascript,${encodeURIComponent(source)}`]));

registerHooks({
  resolve(specifier, context, nextResolve) {
    const stub = tauriStubs.get(specifier);
    if (stub) return { url: stub, shortCircuit: true };
    if (specifier.endsWith(".css")) {
      return { url: "data:text/javascript,export default {}", shortCircuit: true };
    }
    const relativeWithoutExtension = (specifier.startsWith("./") || specifier.startsWith("../"))
      && !/[.]([cm]?js|ts|json)$/.test(specifier);
    return nextResolve(relativeWithoutExtension ? `${specifier}.ts` : specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.startsWith("file:") && url.endsWith(".ts")) {
      return {
        format: "module",
        source: ts.transpileModule(readFileSync(new URL(url), "utf8"), {
          compilerOptions: {
            module: ts.ModuleKind.ESNext,
            target: ts.ScriptTarget.ES2022,
            verbatimModuleSyntax: false,
          },
        }).outputText,
        shortCircuit: true,
      };
    }
    return nextLoad(url, context);
  },
});

globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.location = { search: "", hash: "" };
globalThis.window = { addEventListener() {}, dispatchEvent() {}, close() {} };

const {
  applyAfterProviderIdentityAwait,
  awaitProviderCoordinatorListeners,
  canonicalProviderFetchIdentities,
  commitAgainstLatestProviderState,
  createLocalUsageRefreshCoordinator,
  createProviderIdentityRefreshCoordinator,
  failClosedUnavailableProviderSettings,
  reconcileProviderSettingsChange,
  shouldShowFirstProviderCTA,
} = await import("../src/main.ts");
const { performAntigravityAccountMutation } = await import("../src/settings-provider-detail.ts");

const prior = {
  todayUsd: 3,
  todayTokens: 30,
  last30Usd: 8,
  last30Tokens: 80,
  included: true,
  daily: [],
  models: [],
};

test("clears last-good usage when source leaves canonical enabled set", () => {
  assert.equal(resolveRefreshedUsageReport(prior, null, false), null);
});

test("retains last-good usage only when canonical authorization is proven", () => {
  assert.equal(resolveRefreshedUsageReport(prior, null, true), prior);
  assert.equal(resolveRefreshedUsageReport(prior, null, null), null);
});

test("replaces last-good usage with a fresh report", () => {
  const fresh = { ...prior, todayUsd: 5 };
  assert.equal(resolveRefreshedUsageReport(prior, fresh, true), fresh);
});

test("canonical authorization read failure scans nothing and clears prior usage", async () => {
  let scanCalls = 0;
  const published = [];
  const refresh = createLocalUsageRefreshCoordinator({
    sources: ["claude", "codex"],
    readCanonicalSources: async () => null,
    scanSource: async () => {
      scanCalls += 1;
      return prior;
    },
    previousReport: () => prior,
    beginRefresh() {},
    publishSource: (source, report) => published.push([source, report]),
  });

  await refresh();

  assert.equal(scanCalls, 0);
  assert.deepEqual(published, [["claude", null], ["codex", null]]);
});

test("unavailable provider settings invalidate cached and in-flight identities", () => {
  const invalidated = [];
  const providerIds = failClosedUnavailableProviderSettings(
    ["codex", "claude", "codex"],
    new Set(["grok", "claude"]),
    (ids) => invalidated.push(...ids),
  );

  assert.deepEqual(providerIds, ["codex", "claude", "grok"]);
  assert.deepEqual(invalidated, providerIds);
});

test("first-provider CTA stays hidden for Kiro-only cost evidence and unresolved scans", () => {
  assert.equal(shouldShowFirstProviderCTA(true, 0, 1, false), false);
  assert.equal(shouldShowFirstProviderCTA(true, 0, 0, true), false);
  assert.equal(shouldShowFirstProviderCTA(true, 0, 0, false), true);
});

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test("disable then enable during an in-flight scan rejects its stale completion", async () => {
  const staleScan = deferred();
  const currentReport = { ...prior, todayUsd: 7 };
  let canonical = new Set(["claude"]);
  const published = [];
  let scanCalls = 0;
  let scanStarted;
  const started = new Promise((resolve) => { scanStarted = resolve; });
  const refresh = createLocalUsageRefreshCoordinator({
    sources: ["claude"],
    readCanonicalSources: async () => new Set(canonical),
    scanSource: async () => {
      scanCalls += 1;
      if (scanCalls > 1) return currentReport;
      scanStarted();
      return staleScan.promise;
    },
    previousReport: () => prior,
    beginRefresh() {},
    publishSource: (_source, report) => published.push(report),
  });

  const oldRefresh = refresh();
  await started;
  canonical = new Set();
  const disableRefresh = refresh();
  await disableRefresh;
  assert.deepEqual(published, [null]);

  canonical = new Set(["claude"]);
  await refresh();
  assert.equal(scanCalls, 2);
  assert.deepEqual(published, [null, currentReport]);

  staleScan.resolve({ ...prior, todayUsd: 99 });
  await oldRefresh;
  assert.deepEqual(published, [null, currentReport]);
});

test("enable during an in-flight refresh starts a current scan and publishes it", async () => {
  const blockedCanonicalRead = deferred();
  const enabledReport = { ...prior, todayUsd: 7 };
  let canonical = new Set();
  let canonicalReads = 0;
  let scanCalls = 0;
  const published = [];
  const refresh = createLocalUsageRefreshCoordinator({
    sources: ["claude"],
    readCanonicalSources: async () => {
      canonicalReads += 1;
      if (canonicalReads === 2) return blockedCanonicalRead.promise;
      return new Set(canonical);
    },
    scanSource: async () => {
      scanCalls += 1;
      return enabledReport;
    },
    previousReport: () => null,
    beginRefresh() {},
    publishSource: (_source, report) => published.push(report),
  });

  const disabledRefresh = refresh();
  while (canonicalReads < 2) await Promise.resolve();
  canonical = new Set(["claude"]);
  await refresh();

  assert.equal(scanCalls, 1);
  assert.deepEqual(published, [enabledReport]);
  blockedCanonicalRead.resolve(new Set());
  await disabledRefresh;
  assert.deepEqual(published, [enabledReport]);
});

test("provider settings reconciliation invalidates quota before refreshing projections", async () => {
  const calls = [];
  await reconcileProviderSettingsChange(
    async () => { calls.push("order"); },
    async () => { calls.push("usage"); },
    async () => { calls.push("quota"); return null; },
  );
  assert.equal(calls[0], "quota");
  assert.deepEqual(calls.slice(1).sort(), ["order", "usage"]);
});

test("canonical provider identity ignores presentation but tracks fetch config and enablement", () => {
  const identity = (provider, settings = {}) => canonicalProviderFetchIdentities({
    version: 1,
    ...settings,
    providers: [provider],
  }).get("provider-p");
  const baseline = identity({ id: "provider-p", enabled: true, apiKey: "key-A", displayName: "A" });

  assert.equal(
    identity({ id: "provider-p", enabled: true, apiKey: "key-A", displayName: "Renamed" }),
    baseline,
  );
  assert.notEqual(
    identity({ id: "provider-p", enabled: true, apiKey: "key-B", displayName: "A" }),
    baseline,
  );
  assert.equal(identity({ id: "provider-p", enabled: false, apiKey: "key-A" }), undefined);

  for (const [providerId, selectorKey] of [
    ["codex", "active_codex_account"],
    ["freemodel", "active_freemodel_account"],
    ["elevenlabs", "active_elevenlabs_key"],
    ["hiyo", "active_hiyo_key"],
  ]) {
    const provider = { id: providerId, enabled: true };
    const selected = (value) => canonicalProviderFetchIdentities({
      version: 1,
      [selectorKey]: value,
      providers: [provider],
    }).get(providerId);
    assert.notEqual(selected("identity-A"), selected("identity-B"), providerId);
  }
});

test("newer provider settings revision wins when async reads resolve out of order", async () => {
  const older = deferred();
  const newer = deferred();
  const applied = [];
  const rebuild = async (settings) => { applied.push(settings); };
  const refreshUsage = async () => {};

  const oldApply = reconcileProviderSettingsChange(rebuild, refreshUsage, () => older.promise);
  const newApply = reconcileProviderSettingsChange(rebuild, refreshUsage, () => newer.promise);
  newer.resolve({ settingsRevision: 11, providers: [{ id: "provider-p", enabled: true }] });
  await newApply;
  older.resolve({ settingsRevision: 10, providers: [{ id: "provider-p", enabled: false }] });
  await oldApply;

  assert.equal(applied.length, 1);
  assert.equal(applied[0].settingsRevision, 11);
  assert.equal(applied[0].providers[0].enabled, true);
});

test("Codex pre/post account events discard A and publish one queued B refresh", async () => {
  const completions = { A: deferred(), B: deferred() };
  const started = { A: deferred(), B: deferred() };
  const finishedB = deferred();
  const fetches = [];
  const published = [];
  let activeAccount = "A";
  let inFlight = false;
  let coordinator;

  coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => inFlight,
    forceFetch: async (providerId) => {
      const requestedAccount = activeAccount;
      const generation = coordinator.snapshot(providerId);
      inFlight = true;
      fetches.push(requestedAccount);
      started[requestedAccount].resolve();
      const status = await completions[requestedAccount].promise;
      if (coordinator.isCurrent(providerId, generation)) published.push(status);
      inFlight = false;
      coordinator.onFetchReleased(providerId);
      if (requestedAccount === "B") finishedB.resolve();
    },
  });

  coordinator.invalidateAndRefresh("codex"); // pre-mutation event starts A
  await started.A.promise;
  activeAccount = "B";
  coordinator.invalidateAndRefresh("codex"); // post-mutation event invalidates A
  completions.A.resolve({ account: "A" });

  await started.B.promise;
  assert.deepEqual(published, []);
  completions.B.resolve({ account: "B" });
  await finishedB.promise;

  assert.deepEqual(fetches, ["A", "B"]);
  assert.deepEqual(published, [{ account: "B" }]);
});

test("Antigravity pre/post mutation events discard A and publish queued B", async () => {
  const completions = { A: deferred(), B: deferred() };
  const started = { A: deferred(), B: deferred() };
  const finishedB = deferred();
  const published = [];
  let activeAccount = "A";
  let inFlight = false;
  let coordinator;

  coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => inFlight,
    forceFetch: async (providerId) => {
      const requestedAccount = activeAccount;
      const generation = coordinator.snapshot(providerId);
      inFlight = true;
      started[requestedAccount].resolve();
      const status = await completions[requestedAccount].promise;
      if (coordinator.isCurrent(providerId, generation)) published.push(status);
      inFlight = false;
      coordinator.onFetchReleased(providerId);
      if (requestedAccount === "B") finishedB.resolve();
    },
  });

  const switched = await performAntigravityAccountMutation(
    async () => {
      await started.A.promise;
      activeAccount = "B";
      return "account-B";
    },
    async () => { coordinator.invalidateAndRefresh("antigravity"); },
  );
  assert.equal(switched, "account-B");

  completions.A.resolve({ account: "A" });
  await started.B.promise;
  assert.deepEqual(published, []);
  completions.B.resolve({ account: "B" });
  await finishedB.promise;
  assert.deepEqual(published, [{ account: "B" }]);
});

test("Antigravity failed Settings mutation keeps origin and emits both phases", async () => {
  const changes = [];
  await assert.rejects(
    performAntigravityAccountMutation(
      async () => { throw new Error("invalid credentials"); },
      async (change) => { changes.push(change); },
    ),
    /invalid credentials/,
  );
  assert.deepEqual(changes, [
    { phase: "before", origin: "settings" },
    { phase: "after", origin: "settings" },
  ]);
});

test("provider disable invalidates an in-flight result and never requeues it", async () => {
  const oldCompletion = deferred();
  const published = [];
  const forced = [];
  let inFlight = true;
  const coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => inFlight,
    forceFetch: async (providerId) => { forced.push(providerId); },
  });
  coordinator.initializeCanonicalProviders(new Map([["provider-p", "config-A"]]));

  const oldGeneration = coordinator.snapshot("provider-p");
  const oldFetch = oldCompletion.promise.then((status) => {
    if (coordinator.isCurrent("provider-p", oldGeneration)) published.push(status);
  });
  const change = coordinator.reconcileCanonicalProviders(new Map());
  oldCompletion.resolve({ config: "A" });
  await oldFetch;
  inFlight = false;
  coordinator.onFetchReleased("provider-p");
  await Promise.resolve();

  assert.deepEqual(change.disabledProviderIds, ["provider-p"]);
  assert.deepEqual(published, []);
  assert.deepEqual(forced, []);
});

test("provider disable then enable discards old config and publishes one current refresh", async () => {
  const oldCompletion = deferred();
  const published = [];
  const forced = [];
  let activeConfig = "A";
  let inFlight = true;
  let coordinator;
  coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => inFlight,
    forceFetch: async (providerId) => {
      forced.push(activeConfig);
      const generation = coordinator.snapshot(providerId);
      const status = { config: activeConfig };
      if (coordinator.isCurrent(providerId, generation)) published.push(status);
    },
  });
  coordinator.initializeCanonicalProviders(new Map([["provider-p", "config-A"]]));

  const oldGeneration = coordinator.snapshot("provider-p");
  const oldFetch = oldCompletion.promise.then((status) => {
    if (coordinator.isCurrent("provider-p", oldGeneration)) published.push(status);
  });
  coordinator.reconcileCanonicalProviders(new Map());
  activeConfig = "B";
  coordinator.reconcileCanonicalProviders(new Map([["provider-p", "config-B"]]));
  oldCompletion.resolve({ config: "A" });
  await oldFetch;
  assert.deepEqual(published, []);

  inFlight = false;
  coordinator.onFetchReleased("provider-p");
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(forced, ["B"]);
  assert.deepEqual(published, [{ config: "B" }]);
});

test("identity switch clears cached A before a transient B result is merged", async () => {
  const finished = deferred();
  let cached = { account: "A", windows: [{ remainingPct: 90 }] };
  let coordinator;
  coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => false,
    onIdentityInvalidated: () => { cached = null; },
    forceFetch: async (providerId) => {
      const generation = coordinator.snapshot(providerId);
      const fresh = { account: "B", error: "timeout", windows: [] };
      const merged = cached && fresh.error ? cached : fresh;
      if (coordinator.isCurrent(providerId, generation)) cached = merged;
      finished.resolve();
    },
  });
  coordinator.initializeCanonicalProviders(new Map([["codex", "account-A"]]));

  coordinator.invalidateAndRefresh("codex");
  await finished.promise;

  assert.equal(cached.account, "B");
  assert.equal(cached.error, "timeout");
});

test("settings read failure plus popover switch cannot preserve the previous identity", async () => {
  const fetchStarted = deferred();
  const fetchCompletion = deferred();
  const finished = deferred();
  let cached = { account: "A", windows: [{ remainingPct: 90 }] };
  let coordinator;
  coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => false,
    onIdentityInvalidated: () => { cached = null; },
    forceFetch: async (providerId) => {
      const generation = coordinator.snapshot(providerId);
      fetchStarted.resolve();
      const fresh = await fetchCompletion.promise;
      const merged = cached && fresh.error ? cached : fresh;
      if (coordinator.isCurrent(providerId, generation)) cached = merged;
      finished.resolve();
    },
  });
  coordinator.initializeCanonicalProviders(new Map([["freemodel", "account-A"]]));
  const settingsReadSnapshot = coordinator.snapshot("freemodel");

  // The popover callback invalidates its known provider synchronously and
  // queues B, while PROVIDERS_CHANGED is still awaiting its canonical read.
  coordinator.invalidateAndRefresh("freemodel");
  assert.equal(cached, null);
  await fetchStarted.promise;

  // The settings read fails. Production fail-closes only identities whose
  // generation did not change while awaiting, so it cannot cancel current B.
  coordinator.invalidateForCanonicalReconciliation(
    coordinator.isCurrent("freemodel", settingsReadSnapshot) ? ["freemodel"] : [],
  );
  fetchCompletion.resolve({ account: "B", error: "timeout", windows: [] });
  await finished.promise;

  assert.equal(cached.account, "B");
  assert.equal(cached.error, "timeout");
});

test("settings read failure clears an unresolved cached provider identity", () => {
  let cached = { account: "A" };
  const coordinator = createProviderIdentityRefreshCoordinator({
    isInFlight: () => false,
    onIdentityInvalidated: () => { cached = null; },
    forceFetch: async () => {},
  });
  coordinator.initializeCanonicalProviders(new Map([["freemodel", "account-A"]]));
  const settingsReadSnapshot = coordinator.snapshot("freemodel");

  coordinator.invalidateForCanonicalReconciliation(
    coordinator.isCurrent("freemodel", settingsReadSnapshot) ? ["freemodel"] : [],
  );

  assert.equal(cached, null);
});

test("invalidation during an awaited projection suppresses old-identity side effects", async () => {
  const projection = deferred();
  const sideEffects = [];
  let current = true;
  const applying = applyAfterProviderIdentityAwait(
    projection.promise,
    () => current,
    (value) => sideEffects.push(value),
  );

  current = false;
  projection.resolve("account-A notification");

  assert.equal(await applying, false);
  assert.deepEqual(sideEffects, []);
});

test("unrelated identity invalidation during async merge cannot resurrect cached A", async () => {
  const mergeStarted = deferred();
  const releaseFirstMerge = deferred();
  let revision = 0;
  let mergeCalls = 0;
  let statuses = [{ id: "provider-x" }, { id: "codex", account: "A" }];
  let committed = [];
  const resolving = commitAgainstLatestProviderState(
    () => revision,
    async () => {
      const captured = [...statuses];
      mergeCalls += 1;
      if (mergeCalls === 1) {
        mergeStarted.resolve();
        await releaseFirstMerge.promise;
      }
      return captured;
    },
    (value) => { committed = value; },
  );

  await mergeStarted.promise;
  statuses = statuses.filter((status) => status.id !== "codex");
  revision += 1;
  releaseFirstMerge.resolve();

  assert.equal(await resolving, true);
  assert.deepEqual(committed, [{ id: "provider-x" }]);
  assert.equal(mergeCalls, 2);
});

test("concurrent provider merges commit atomically and preserve both results", async () => {
  const release = deferred();
  let revision = 0;
  let statuses = [];
  const calls = new Map();
  const mergeProvider = (id) => commitAgainstLatestProviderState(
    () => revision,
    async () => {
      const captured = [...statuses];
      const count = (calls.get(id) ?? 0) + 1;
      calls.set(id, count);
      if (count === 1) await release.promise;
      return [...captured, { id }];
    },
    (merged) => {
      statuses = merged;
      revision += 1;
    },
  );

  const mergingA = mergeProvider("provider-a");
  const mergingB = mergeProvider("provider-b");
  await Promise.resolve();
  release.resolve();
  await Promise.all([mergingA, mergingB]);

  assert.deepEqual(statuses.map((status) => status.id).sort(), ["provider-a", "provider-b"]);
  assert.equal((calls.get("provider-a") ?? 0) + (calls.get("provider-b") ?? 0), 3);
});

test("startup load waits for both provider coordinator listeners", async () => {
  const accountListener = deferred();
  const settingsListener = deferred();
  let loadStarted = false;
  const startup = (async () => {
    await awaitProviderCoordinatorListeners([
      accountListener.promise,
      settingsListener.promise,
    ]);
    loadStarted = true;
  })();

  await Promise.resolve();
  assert.equal(loadStarted, false);
  accountListener.resolve();
  await Promise.resolve();
  assert.equal(loadStarted, false);
  settingsListener.resolve();
  await startup;
  assert.equal(loadStarted, true);
});
