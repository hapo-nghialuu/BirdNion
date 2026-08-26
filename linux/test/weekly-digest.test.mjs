import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import ts from "typescript";

const tauriStubs = new Map(Object.entries({
  "@tauri-apps/api/core": `
    export async function invoke(command, args) {
      return globalThis.__weeklyDigestInvoke(command, args);
    }
  `,
  "@tauri-apps/api/app": "export async function getVersion() { return 'test'; }",
  "@tauri-apps/api/event": "export async function emit() {}",
  "@tauri-apps/plugin-opener": "export async function openUrl() {}",
}).map(([specifier, source]) => [specifier, `data:text/javascript,${encodeURIComponent(source)}`]));

registerHooks({
  resolve(specifier, context, nextResolve) {
    const stub = tauriStubs.get(specifier);
    if (stub) return { url: stub, shortCircuit: true };
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

const values = new Map();
globalThis.localStorage = {
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
};

const {
  checkWeeklyDigest,
  setWeeklyDigestEnabled,
} = await import("../src/weekly-digest.ts");

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function dateKey(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function report(source, usd, tokens) {
  return {
    todayUsd: usd,
    todayTokens: tokens,
    last30Usd: usd,
    last30Tokens: tokens,
    daily: [{
      date: dateKey(),
      usd,
      tokens,
      models: [{ name: `${source}-model`, usd, tokens }],
    }],
    hourly: [],
    topModel: `${source}-model`,
    included: true,
    live: true,
    scannedAt: Date.now(),
  };
}

function resetDigest() {
  values.clear();
  values.set("birdnion.lang", "en");
  setWeeklyDigestEnabled(true);
}

test("excludes Kiro when it leaves the canonical source set during its scan", async () => {
  resetDigest();
  const kiroScan = deferred();
  const kiroStarted = deferred();
  const notifications = [];
  let canonicalSources = ["claude", "kiro"];
  let canonicalReads = 0;

  globalThis.__weeklyDigestInvoke = async (command, args) => {
    if (command === "enabled_local_usage_source_ids") {
      canonicalReads += 1;
      return [...canonicalSources];
    }
    if (command === "claude_usage_report") return report("claude", 1, 10);
    if (command === "kiro_usage_report") {
      kiroStarted.resolve();
      return kiroScan.promise;
    }
    if (command === "notify") {
      notifications.push(args);
      return null;
    }
    throw new Error(`Unexpected command: ${command}`);
  };

  const checking = checkWeeklyDigest();
  await kiroStarted.promise;
  canonicalSources = ["claude"];
  kiroScan.resolve(report("kiro", 99, 990));
  await checking;

  assert.equal(canonicalReads, 2);
  assert.equal(notifications.length, 1);
  assert.match(notifications[0].body, /\$1\.00/);
  assert.match(notifications[0].body, /Top source: Claude/);
  assert.doesNotMatch(notifications[0].body, /Kiro|\$100\.00/);
});

test("does not notify when the digest is disabled during a scan", async () => {
  resetDigest();
  const kiroScan = deferred();
  const kiroStarted = deferred();
  const notifications = [];

  globalThis.__weeklyDigestInvoke = async (command, args) => {
    if (command === "enabled_local_usage_source_ids") return ["kiro"];
    if (command === "kiro_usage_report") {
      kiroStarted.resolve();
      return kiroScan.promise;
    }
    if (command === "notify") {
      notifications.push(args);
      return null;
    }
    throw new Error(`Unexpected command: ${command}`);
  };

  const checking = checkWeeklyDigest();
  await kiroStarted.promise;
  setWeeklyDigestEnabled(false);
  kiroScan.resolve(report("kiro", 7, 70));
  await checking;

  assert.deepEqual(notifications, []);
});

test("keeps Kiro in the digest when it remains canonically authorized", async () => {
  resetDigest();
  const notifications = [];
  let canonicalReads = 0;

  globalThis.__weeklyDigestInvoke = async (command, args) => {
    if (command === "enabled_local_usage_source_ids") {
      canonicalReads += 1;
      return ["kiro"];
    }
    if (command === "kiro_usage_report") return report("kiro", 7, 70);
    if (command === "notify") {
      notifications.push(args);
      return null;
    }
    throw new Error(`Unexpected command: ${command}`);
  };

  await checkWeeklyDigest();

  assert.equal(canonicalReads, 2);
  assert.equal(notifications.length, 1);
  assert.match(notifications[0].body, /\$7\.00/);
  assert.match(notifications[0].body, /Top source: Kiro/);
});
