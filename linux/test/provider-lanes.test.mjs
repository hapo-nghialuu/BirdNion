import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import ts from "typescript";

// Same TS-transpile hook as usage-refresh-state.test.mjs — provider-lanes.ts
// has no external imports, so no Tauri stubs are needed here.
registerHooks({
  resolve(specifier, context, nextResolve) {
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

const {
  adaptiveBackoffMultiplier,
  createTtlCache,
  mergeStatusExtras,
  ProviderLane,
  ProviderLanes,
} = await import("../src/provider-lanes.ts");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("ProbeLaneDedup: three concurrent kicks run one underlying fetch", async () => {
  const lane = new ProviderLane("p");
  let runs = 0;
  const run = async () => { runs += 1; await tick(); };
  await Promise.all([
    lane.kick(false, "background", run),
    lane.kick(false, "background", run),
    lane.kick(false, "background", run),
  ]);
  assert.equal(runs, 1, "concurrent kicks must join a single fetch");
});

test("ProbeLaneDedup: force kick during in-flight queues exactly one follow-up", async () => {
  const lane = new ProviderLane("p");
  const runs = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  const first = lane.kick(false, "background", async () => { runs.push("first"); await gate; });
  const forced = lane.kick(true, "manual", async () => { runs.push("follow-up"); });
  const forcedAgain = lane.kick(true, "manual", async () => { runs.push("third"); });
  release();
  await Promise.all([first, forced, forcedAgain]);
  assert.deepEqual(runs, ["first", "follow-up"],
    "two force kicks during one in-flight fetch must coalesce to one follow-up");
});

test("lane clears inFlight after rejection so the next kick refetches", async () => {
  const lane = new ProviderLane("p");
  await assert.rejects(lane.kick(false, "background", async () => { throw new Error("ipc"); }));
  assert.equal(lane.inFlight, null);
  let ran = false;
  await lane.kick(false, "background", async () => { ran = true; });
  assert.equal(ran, true);
});

test("joiner waits for the owner's fetch to settle", async () => {
  const lane = new ProviderLane("p");
  const order = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  const owner = lane.kick(false, "background", async () => { await gate; order.push("owner-done"); });
  const joiner = lane.kick(false, "background", async () => { order.push("joiner-ran"); });
  release();
  await Promise.all([owner, joiner]);
  assert.deepEqual(order, ["owner-done"], "joiner's run is dropped; it joins the owner");
});

test("backoff multiplies the provider's own interval x1/x2/x4/x8 capped", () => {
  const lane = new ProviderLane("p");
  const now = 1_000_000;
  assert.equal(lane.intervalMs(10_000), 10_000);
  for (let streak = 1; streak <= 6; streak += 1) {
    lane.lastInteraction = "background";
    lane.recordOutcome(false, now + streak);
  }
  // 6 failures → capped at x8
  assert.equal(lane.intervalMs(10_000), 80_000);
  lane.resetSchedule();
  lane.recordOutcome(false, now);
  assert.equal(lane.intervalMs(10_000), 10_000, "first failure keeps base interval");
  lane.recordOutcome(false, now);
  assert.equal(lane.intervalMs(10_000), 20_000);
  lane.recordOutcome(false, now);
  assert.equal(lane.intervalMs(10_000), 40_000);
  lane.recordOutcome(false, now);
  assert.equal(lane.intervalMs(10_000), 80_000);
  lane.recordOutcome(false, now);
  assert.equal(lane.intervalMs(10_000), 80_000, "cap at x8");
  assert.equal(adaptiveBackoffMultiplier(0), 1);
});

test("isDue honors lastFetched + backoff-adjusted interval", () => {
  const lane = new ProviderLane("p");
  const t0 = 5_000_000;
  assert.equal(lane.isDue(t0, 60_000), true, "never fetched is due");
  lane.recordOutcome(true, t0);
  assert.equal(lane.isDue(t0 + 59_999, 60_000), false);
  assert.equal(lane.isDue(t0 + 60_000, 60_000), true);
  // One failure → still x1; second failure → x2 ⇒ not due until 120s.
  lane.recordOutcome(false, t0);
  lane.recordOutcome(false, t0);
  assert.equal(lane.isDue(t0 + 60_000, 60_000), false);
  assert.equal(lane.isDue(t0 + 120_000, 60_000), true);
});

test("manual-kick failure starts a fresh streak instead of inheriting backoff", async () => {
  const lane = new ProviderLane("p");
  const t0 = 9_000_000;
  // Build a background streak of 3 (x4 interval).
  lane.recordOutcome(false, t0);
  lane.recordOutcome(false, t0);
  lane.recordOutcome(false, t0);
  assert.equal(lane.failureStreak, 3);
  // A manual retry that fails counts as failure #1, not #4.
  await lane.kick(true, "manual", async () => {
    lane.recordOutcome(false, t0 + 1);
  });
  assert.equal(lane.failureStreak, 1);
});

test("ProbeExtrasMerge: enrichment fills gaps, core fields untouched", () => {
  const windows = [{ label: "5h", usedPct: 40, remainingPct: 60 }];
  const core = {
    id: "codex",
    displayName: "Codex",
    windows,
    lastUpdated: 111,
    error: "core error stays",
    accountLabel: "work",
    creditsRemaining: 7,
    sourceLabel: "OAuth",
  };
  mergeStatusExtras(core, {
    id: "codex",
    displayName: "Codex",
    windows: [{ label: "EVIL", usedPct: 99, remainingPct: 1 }],
    lastUpdated: 999,
    error: "must not land",
    accountLabel: "other",
    version: "1.2.3",
    serviceStatus: "Operational",
    serviceStatusLevel: "none",
    resetCreditsAvailable: 4,
    signedInEmail: "a@b.c",
    creditsRemaining: 99,
    creditsUnlimited: true,
  });
  assert.equal(core.version, "1.2.3");
  assert.equal(core.serviceStatus, "Operational");
  assert.equal(core.serviceStatusLevel, "none");
  assert.equal(core.resetCreditsAvailable, 4);
  assert.equal(core.signedInEmail, "a@b.c");
  assert.equal(core.creditsUnlimited, true);
  // Core-owned fields survive even though the extras payload carried values.
  assert.equal(core.windows, windows);
  assert.equal(core.error, "core error stays");
  assert.equal(core.accountLabel, "work");
  assert.equal(core.sourceLabel, "OAuth");
  assert.equal(core.creditsRemaining, 7, "core credits win over extras");
  assert.equal(core.lastUpdated, 111, "extras never bumps lastUpdated");
});

test("ProbeExtrasMerge: missing enrichment fields never clobber existing ones", () => {
  const core = { id: "x", version: "keep", creditsUnlimited: false };
  mergeStatusExtras(core, { id: "x", version: undefined, creditsUnlimited: false });
  assert.equal(core.version, "keep");
  assert.equal(core.creditsUnlimited, false);
  // An extras true still ORs in.
  mergeStatusExtras(core, { id: "x", creditsUnlimited: true });
  assert.equal(core.creditsUnlimited, true);
});

test("ProviderLanes: registry shares lanes by id and reports in-flight ids", async () => {
  const lanes = new ProviderLanes();
  const a = lanes.lane("a");
  assert.equal(lanes.lane("a"), a);
  assert.notEqual(lanes.lane("b"), a);
  let release;
  const gate = new Promise((r) => { release = r; });
  const p = a.kick(false, "background", async () => { await gate; });
  assert.equal(lanes.isInFlight("a"), true);
  assert.equal(lanes.isInFlight("b"), false);
  assert.deepEqual([...lanes.inFlightIds()], ["a"]);
  release();
  await p;
  assert.equal(lanes.isInFlight("a"), false);
  assert.equal(lanes.inFlightIds().size, 0);
});

test("createTtlCache: at most one IPC per ttl window of ticks", async () => {
  let now = 0;
  let calls = 0;
  const get = createTtlCache(30_000, async () => { calls += 1; return calls; }, () => now);
  // Simulate six 10s ticks.
  const seen = [];
  for (let tickN = 0; tickN < 6; tickN += 1) {
    now = tickN * 10_000;
    seen.push(await get());
  }
  assert.equal(calls, 2, "60s of ticks must cost exactly two fetches");
  assert.deepEqual(seen, [1, 1, 1, 2, 2, 2]);
});
